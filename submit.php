<?php
/**
 * Обработчик заявок с лендинга.
 *
 * Почта отправляется через SMTP с авторизацией под ящиком info@ (функция
 * smtp_send ниже, без внешних библиотек) — так письмо действительно
 * подписывается доменом на уровне сессии, а не только SPF/DKIM-записями,
 * и не теряется на стороне Gmail, как это было с голой функцией mail().
 * Если SMTP не настроен в config.local.php, используется mail() как раньше —
 * это резервный, менее надёжный путь.
 *
 * Также дублирует заявку в Telegram и пишет CSV-журнал.
 *
 * Настройки — в config.local.php (скопируйте из config.example.php).
 * Этот файл не попадает в git: пароль от почты и токен бота дают полный доступ к нему.
 */

ini_set('display_errors', '0');   // предупреждения PHP не должны ломать JSON-ответ форме

$configFile = __DIR__ . '/config.local.php';
$cfg = is_file($configFile) ? require $configFile : [];

$MIN_SECONDS_BETWEEN = $cfg['min_seconds_between'] ?? 20;

// Журнал заявок — на уровень выше public_html, куда веб-сервер не отдаёт файлы.
// Если туда писать нельзя, остаётся рядом; там его закрывает .htaccess.
$logDir   = is_writable(dirname(__DIR__)) ? dirname(__DIR__) : __DIR__;
$LOG_FILE = $logDir . '/leads.csv';

date_default_timezone_set('Asia/Krasnoyarsk');   // Красноярск живёт по красноярскому времени (МСК+4, UTC+7) — не по московскому

function notify_lead(array $lead, array $cfg, $logDir) {
    $TG_TOKEN   = $cfg['tg_token']  ?? '';
    $TG_CHAT    = $cfg['tg_chat']   ?? '';
    $MAIL_TO    = $cfg['mail_to']   ?? '';
    $MAIL_FROM  = $cfg['mail_from'] ?? '';
    $SMS_API_ID = $cfg['sms_api_id'] ?? '';
    $SMS_TO     = $cfg['sms_to']     ?? '';
    $TG_IPV6    = !empty($cfg['tg_ipv6']);

    // SMTP-авторизация для почты. Обычно smtp_user совпадает с mail_from.
    $SMTP_HOST   = $cfg['smtp_host']   ?? '';
    $SMTP_PORT   = $cfg['smtp_port']   ?? 465;
    $SMTP_SECURE = $cfg['smtp_secure'] ?? 'ssl';   // 'ssl' (обычно порт 465) или 'tls' (STARTTLS, обычно порт 587)
    $SMTP_USER   = $cfg['smtp_user']   ?? '';
    $SMTP_PASS   = $cfg['smtp_pass']   ?? '';

    $phone = $lead['phone'];
    $text = $lead['text'];
    $smsText = $lead['sms'];

    // ---- Telegram ----
    // Из России api.telegram.org часто недоступен. Чтобы посетитель не ждал
    // таймаута на каждой заявке, после неудачи канал отключается на 10 минут.
    $sent = false;
    $breaker = $logDir . '/telegram-down.txt';
    $tgMuted = is_file($breaker) && (time() - (int)@file_get_contents($breaker) < 600);

    if ($TG_TOKEN && $TG_CHAT && !$tgMuted && function_exists('curl_init')) {
        $ch = curl_init("https://api.telegram.org/bot{$TG_TOKEN}/sendMessage");
        $opts = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_TIMEOUT        => 7,
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => ['chat_id' => $TG_CHAT, 'text' => $text],
        ];
        if ($TG_IPV6) $opts[CURLOPT_IPRESOLVE] = CURL_IPRESOLVE_V6;
        curl_setopt_array($ch, $opts);
        $response = curl_exec($ch);
        $result = $response === false ? null : json_decode($response, true);
        $sent = curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200 && ($result['ok'] ?? false) === true;
        curl_close($ch);
        if ($sent) { @unlink($breaker); } else { @file_put_contents($breaker, time()); }
    }

    // ---- SMS (sms.ru) ----
    // Мгновенное уведомление на телефон там, где мессенджеры недоступны.
    if ($SMS_API_ID && $SMS_TO && function_exists('curl_init')) {
        $ch = curl_init('https://sms.ru/sms/send');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_TIMEOUT        => 7,
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => [
                'api_id' => $SMS_API_ID,
                'to'     => $SMS_TO,
                'msg'    => mb_substr($smsText, 0, 120),
                'json'   => 1,
            ],
        ]);
        $response = curl_exec($ch);
        curl_close($ch);
        $result = $response === false ? null : json_decode($response, true);
        foreach (($result['sms'] ?? []) as $recipient) {
            if (($recipient['status'] ?? '') === 'OK') $sent = true;
        }
    }

    // ---- Почта ----
    if ($MAIL_TO && $SMTP_HOST && $SMTP_USER && $SMTP_PASS) {
        $r = smtp_send($SMTP_HOST, $SMTP_PORT, $SMTP_SECURE, $SMTP_USER, $SMTP_PASS,
            $MAIL_FROM ?: $SMTP_USER, 'Сайт', $MAIL_TO, 'Заявка с сайта: ' . $phone, $text);
        if ($r['ok']) $sent = true;
    } elseif ($MAIL_TO && $MAIL_FROM) {
        // Резервный путь без авторизации — используется, только если SMTP не настроен.
        // Менее надёжен: письма могут не доходить без явной авторизации на некоторых хостингах.
        $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
        $headers  = "From: " . $utf('Сайт') . " <{$MAIL_FROM}>\r\n";
        $headers .= "MIME-Version: 1.0\r\n";
        $headers .= "Content-Type: text/plain; charset=utf-8\r\n";
        if (@mail($MAIL_TO, $utf('Заявка с сайта: ' . $phone), $text, $headers)) $sent = true;
    }

    return $sent;
}

// Сохраняем заявку до сетевых вызовов. Блокировка защищает запись от других PHP-процессов.
function save_lead($logFile, array $row) {
    $file = @fopen($logFile, 'a');
    if (!$file) return false;

    $saved = false;
    if (flock($file, LOCK_EX)) {
        // Excel распознаёт как формулы строки, начинающиеся с =, +, - или @.
        $cells = array_map(function ($value) {
            return preg_match('/^[=+\-@]/', (string)$value) ? "'" . $value : $value;
        }, $row);
        $saved = fputcsv($file, $cells, ',', '"', '') > 0 && fflush($file);
    }
    $closed = fclose($file);
    return $saved && $closed;
}

// Временная очередь повторной доставки лежит за пределами public_html.
function queue_lead($queueDir, array $lead) {
    if (is_link($queueDir)) return false;
    $lastRun = @filemtime($queueDir . '/retry.lock');
    if ($lastRun === false || time() - $lastRun > 3600) return false;

    $file = @tempnam($queueDir, 'pending-');
    if ($file === false) return false;
    $body = json_encode($lead + ['queued_at' => time()], JSON_INVALID_UTF8_SUBSTITUTE);
    if ($body !== false && dirname($file) === $queueDir
        && @file_put_contents($file, $body) === strlen($body)
        && @rename($file, $file . '.json')) {
        return true;
    }
    @unlink($file);
    return false;
}

function retry_leads($queueDir, array $cfg, $logDir) {
    if (is_link($queueDir)) return;
    if (!is_dir($queueDir) && !@mkdir($queueDir, 0700) && !is_dir($queueDir)) {
        error_log('Не удалось создать очередь заявок.');
        return;
    }
    $lock = @fopen($queueDir . '/retry.lock', 'c');
    if (!$lock) {
        error_log('Не удалось открыть блокировку очереди заявок.');
        return;
    }
    if (!flock($lock, LOCK_EX | LOCK_NB)) {
        fclose($lock);
        return;
    }

    // HTTP-обработчик добавляет записи, пока планировщик регулярно запускает очередь.
    touch($queueDir . '/retry.lock');
    $now = time();
    $attempted = 0;
    foreach (glob($queueDir . '/pending-*.json') ?: [] as $file) {
        if (!is_file($file) || is_link($file)) continue;
        if (filemtime($file) > $now) continue;

        $body = @file_get_contents($file);
        $lead = $body === false ? null : json_decode($body, true);
        if (!is_array($lead) || !isset($lead['queued_at'], $lead['phone'], $lead['text'], $lead['sms'])) {
            error_log('В очереди заявок обнаружена нечитаемая запись.');
            @unlink($file);
            continue;
        }
        if ($now - $lead['queued_at'] >= 86400) {
            error_log('Уведомление о заявке не принято за сутки. Заявка осталась в leads.csv.');
            @unlink($file);
            continue;
        }

        if ($attempted >= 3) break;
        if (!@touch($file, $now + 1800)) {
            error_log('Не удалось назначить повторную попытку отправки заявки.');
            continue;
        }
        ++$attempted;
        if (notify_lead($lead, $cfg, $logDir) && !@unlink($file)) {
            error_log('Канал принял уведомление, но убрать его из очереди не удалось.');
        }
    }
    fclose($lock);
}

$queueDir = dirname(__DIR__) . '/.lead-outbox';
if (PHP_SAPI === 'cli' && ($argv[1] ?? '') === '--retry-leads') {
    retry_leads($queueDir, $cfg, $logDir);
    exit;
}

header('Content-Type: application/json; charset=utf-8');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    exit(json_encode(['ok' => false, 'error' => 'method']));
}

// Ловушка для ботов: поле скрыто от людей, заполняется только автоматикой.
if (!empty($_POST['company'])) {
    exit(json_encode(['ok' => true, 'notified' => false]));   // молча принимаем, но никуда не отправляем
}

// Простой лимит по частоте.
session_start();
$now = time();
if (isset($_SESSION['last_lead']) && $now - $_SESSION['last_lead'] < $MIN_SECONDS_BETWEEN) {
    http_response_code(429);
    exit(json_encode(['ok' => false, 'error' => 'too_fast']));
}

function clean($key, $limit = 200) {
    $v = isset($_POST[$key]) ? (string)$_POST[$key] : '';
    $v = strip_tags(trim($v));
    return mb_substr($v, 0, $limit);
}

// Минимальный SMTP-клиент с AUTH LOGIN, без внешних библиотек.
function smtp_send($host, $port, $secure, $user, $pass, $fromEmail, $fromName, $to, $subject, $bodyText) {
    $errno = 0; $errstr = '';
    $ctx = stream_context_create(['ssl' => [
        'verify_peer' => true, 'verify_peer_name' => true, 'allow_self_signed' => false,
    ]]);
    $prefix = ($secure === 'ssl') ? 'ssl://' : 'tcp://';
    $fp = @stream_socket_client($prefix . $host . ':' . $port, $errno, $errstr, 12, STREAM_CLIENT_CONNECT, $ctx);
    if (!$fp) return ['ok' => false, 'error' => "connect {$host}:{$port} — {$errstr} ({$errno})"];
    stream_set_timeout($fp, 12);

    $readResp = function () use ($fp) {
        $data = ''; $code = '';
        do {
            $line = fgets($fp, 1000);
            if ($line === false) break;
            $data .= $line;
            $code = substr($line, 0, 3);
        } while (isset($line[3]) && $line[3] === '-');
        return [$code, trim($data)];
    };
    $cmd = function ($c) use ($fp) { fwrite($fp, $c . "\r\n"); };

    list($code, $resp) = $readResp();
    if ($code !== '220') { fclose($fp); return ['ok' => false, 'error' => "greeting: $resp"]; }

    $cmd('EHLO ' . $host);
    list($code, $resp) = $readResp();
    if ($code !== '250') { fclose($fp); return ['ok' => false, 'error' => "ehlo: $resp"]; }

    if ($secure === 'tls') {
        $cmd('STARTTLS');
        list($code, $resp) = $readResp();
        if ($code !== '220') { fclose($fp); return ['ok' => false, 'error' => "starttls: $resp"]; }
        if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
            fclose($fp); return ['ok' => false, 'error' => 'tls handshake failed'];
        }
        $cmd('EHLO ' . $host);
        list($code, $resp) = $readResp();
        if ($code !== '250') { fclose($fp); return ['ok' => false, 'error' => "ehlo2: $resp"]; }
    }

    $cmd('AUTH LOGIN');
    list($code, $resp) = $readResp();
    if ($code !== '334') { fclose($fp); return ['ok' => false, 'error' => "auth-login: $resp"]; }
    $cmd(base64_encode($user));
    list($code, $resp) = $readResp();
    if ($code !== '334') { fclose($fp); return ['ok' => false, 'error' => "auth-user: $resp"]; }
    $cmd(base64_encode($pass));
    list($code, $resp) = $readResp();
    if ($code !== '235') { fclose($fp); return ['ok' => false, 'error' => "auth-pass: $resp"]; }

    $cmd("MAIL FROM:<{$fromEmail}>");
    list($code, $resp) = $readResp();
    if ($code !== '250') { fclose($fp); return ['ok' => false, 'error' => "mail-from: $resp"]; }

    $cmd("RCPT TO:<{$to}>");
    list($code, $resp) = $readResp();
    if ($code !== '250' && $code !== '251') { fclose($fp); return ['ok' => false, 'error' => "rcpt-to: $resp"]; }

    $cmd('DATA');
    list($code, $resp) = $readResp();
    if ($code !== '354') { fclose($fp); return ['ok' => false, 'error' => "data: $resp"]; }

    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $headers = "From: " . $utf($fromName) . " <{$fromEmail}>\r\n"
             . "To: <{$to}>\r\n"
             . "Subject: " . $utf($subject) . "\r\n"
             . "Date: " . date('r') . "\r\n"
             . "MIME-Version: 1.0\r\n"
             . "Content-Type: text/plain; charset=utf-8\r\n";

    $body = str_replace("\r\n", "\n", $bodyText);
    $body = str_replace("\n", "\r\n", $body);
    $body = preg_replace('/^\./m', '..', $body);   // dot-stuffing по RFC 5321

    $cmd($headers . "\r\n" . $body . "\r\n.");
    list($code, $resp) = $readResp();
    $cmd('QUIT');
    fclose($fp);

    if ($code !== '250') return ['ok' => false, 'error' => "send: $resp"];
    return ['ok' => true];
}

$name  = clean('name', 80);
$phone = clean('phone', 30);
$car   = clean('car', 120);
$sum   = clean('amount', 60);
$cSum  = clean('calc_sum', 40);
$cTerm = clean('calc_term', 20);
$cCar  = clean('calc_car', 40);
$page  = clean('page', 200);

// Телефон обязателен и должен содержать не меньше 10 цифр.
$digits = preg_replace('/\D+/', '', $phone);
if (strlen($digits) < 10) {
    http_response_code(422);
    exit(json_encode(['ok' => false, 'error' => 'phone']));
}

// Без согласия на обработку ПДн заявку не принимаем, даже если форму обошли.
if (($_POST['consent'] ?? '') !== '1') {
    http_response_code(422);
    exit(json_encode(['ok' => false, 'error' => 'consent']));
}

$_SESSION['last_lead'] = $now;

$ip  = $_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? '';
$utm = [];
foreach (['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content'] as $k) {
    if (!empty($_POST[$k])) $utm[] = $k . '=' . clean($k, 60);
}

$lines = [
    "🚗 Новая заявка с сайта",
    "",
    "Имя: "      . ($name  !== '' ? $name  : '—'),
    "Телефон: "  . $phone,
    "Авто: "     . ($car   !== '' ? $car   : '—'),
    "Сумма: "    . ($sum   !== '' ? $sum   : '—'),
    "Калькулятор: {$cSum} на {$cTerm}, авто {$cCar}",
    "Страница: " . ($page !== '' ? $page : '/'),
];
if ($utm)  $lines[] = "Метки: " . implode(' · ', $utm);
$lines[] = "Время: " . date('d.m.Y H:i');
$text = implode("\n", $lines);

$row = [date('Y-m-d H:i:s'), $name, $phone, $car, $sum, $cSum, $cTerm, $page, implode(' ', $utm), $ip];
$saved = save_lead($LOG_FILE, $row);
if (!$saved) error_log('Не удалось сохранить заявку в leads.csv.');

$lead = [
    'phone' => $phone,
    'text' => $text,
    'sms' => 'Заявка ' . $phone . ($car !== '' ? ', ' . $car : '') . ($sum !== '' ? ', ' . $sum : ''),
];
$notified = notify_lead($lead, $cfg, $logDir);
if (!$notified && !$saved) {
    http_response_code(500);
    exit(json_encode(['ok' => false, 'error' => 'delivery']));
}

if (!$notified && !queue_lead($queueDir, $lead)) {
    error_log('Заявка осталась в leads.csv, записать уведомление в очередь не удалось.');
}

echo json_encode(['ok' => true, 'notified' => $notified]);
