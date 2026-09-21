<?php
/**
 * Обработчик заявок с лендинга.
 * Отправляет заявку в Telegram и дублирует на почту, пишет CSV-журнал.
 *
 * Настройки — в config.local.php (скопируйте из config.example.php).
 * Этот файл не попадает в git: токен бота даёт полный доступ к нему.
 */

ini_set('display_errors', '0');   // предупреждения PHP не должны ломать JSON-ответ форме

$configFile = __DIR__ . '/config.local.php';
$cfg = is_file($configFile) ? require $configFile : [];

$TG_TOKEN   = $cfg['tg_token']  ?? '';
$TG_CHAT    = $cfg['tg_chat']   ?? '';
$MAIL_TO    = $cfg['mail_to']   ?? '';
$MAIL_FROM  = $cfg['mail_from'] ?? '';
$SMS_API_ID = $cfg['sms_api_id'] ?? '';
$SMS_TO     = $cfg['sms_to']     ?? '';
$TG_IPV6    = !empty($cfg['tg_ipv6']);
$MIN_SECONDS_BETWEEN = $cfg['min_seconds_between'] ?? 20;

// Журнал заявок — на уровень выше public_html, куда веб-сервер не отдаёт файлы.
// Если туда писать нельзя, остаётся рядом; там его закрывает .htaccess.
$logDir   = is_writable(dirname(__DIR__)) ? dirname(__DIR__) : __DIR__;
$LOG_FILE = $logDir . '/leads.csv';

date_default_timezone_set('Asia/Krasnoyarsk');   // Красноярск живёт по красноярскому времени (МСК+4, UTC+7) — не по московскому
header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    exit(json_encode(['ok' => false, 'error' => 'method']));
}

// Ловушка для ботов: поле скрыто от людей, заполняется только автоматикой.
if (!empty($_POST['company'])) {
    exit(json_encode(['ok' => true]));   // молча принимаем, но никуда не отправляем
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

// ---- Telegram ----
// Из России api.telegram.org часто недоступен. Чтобы посетитель не ждал
// таймаута на каждой заявке, после неудачи канал отключается на 10 минут.
$sent = false;
$breaker = $logDir . '/telegram-down.txt';
$tgMuted = is_file($breaker) && (time() - (int)@file_get_contents($breaker) < 600);

if ($TG_TOKEN && $TG_CHAT && !$tgMuted) {
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
    $sent = curl_exec($ch) !== false && curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200;
    if ($sent) { @unlink($breaker); } else { @file_put_contents($breaker, time()); }
}

// ---- SMS (sms.ru) ----
// Мгновенное уведомление на телефон там, где мессенджеры недоступны.
if ($SMS_API_ID && $SMS_TO) {
    $smsText = 'Заявка ' . $phone . ($car !== '' ? ', ' . $car : '') . ($sum !== '' ? ', ' . $sum : '');
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
    $r = curl_exec($ch);
    if ($r !== false && strpos($r, '"status":"OK"') !== false) $sent = true;
}

// ---- Почта ----
// DEBUG-ВРЕМЕННО: $mailOk/$mailErr фиксируют, что реально ответил mail(), чтобы не гадать.
$mailOk = false;
$mailErr = null;
if ($MAIL_TO && $MAIL_FROM) {
    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $headers  = "From: " . $utf('Сайт') . " <{$MAIL_FROM}>\r\n";
    $headers .= "MIME-Version: 1.0\r\n";
    $headers .= "Content-Type: text/plain; charset=utf-8\r\n";
    $mailOk = mail($MAIL_TO, $utf('Заявка с сайта: ' . $phone), $text, $headers);
    if (!$mailOk) {
        $e = error_get_last();
        $mailErr = $e ? $e['message'] : 'mail() вернул false без деталей ошибки';
    }
    if ($mailOk) $sent = true;
}

// ---- Журнал ----
// Excel исполняет ячейки, начинающиеся с = + - @, как формулы — экранируем.
$csvSafe = function ($v) {
    return preg_match('/^[=+\-@]/', (string)$v) ? "'" . $v : $v;
};
// DEBUG-ВРЕМЕННО: $csvOk/$csvErr фиксируют, удалась ли запись в журнал и куда.
$csvOk = false;
$csvErr = null;
if ($fh = @fopen($LOG_FILE, 'a')) {
    $row = [date('Y-m-d H:i:s'), $name, $phone, $car, $sum, $cSum, $cTerm, $page, implode(' ', $utm), $ip];
    fputcsv($fh, array_map($csvSafe, $row), ',', '"', '');
    fclose($fh);
    $csvOk = true;
    $sent = true;
} else {
    $e = error_get_last();
    $csvErr = $e ? $e['message'] : 'fopen() не удалось, без деталей ошибки';
}

// DEBUG-ВРЕМЕННО: блок диагностики. Удалить вместе с полем 'debug' ниже, когда разберёмся с доставкой.
$debug = [
    'mail_attempted' => (bool)($MAIL_TO && $MAIL_FROM),
    'mail_ok'        => $mailOk,
    'mail_error'     => $mailErr,
    'csv_ok'         => $csvOk,
    'csv_error'      => $csvErr,
    'log_file'       => $LOG_FILE,
    'log_dir_writable' => is_writable($logDir),
];

if (!$sent) {
    http_response_code(500);
    exit(json_encode(['ok' => false, 'error' => 'delivery', 'debug' => $debug]));
}

echo json_encode(['ok' => true, 'debug' => $debug]);
