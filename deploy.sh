#!/bin/bash
# Выкладка сайта на хостинг Timeweb по FTP.
#
#   bash deploy.sh
#
# Пароль FTP и токен бота вводятся с клавиатуры, в файлы на этом компьютере
# не записываются и в список процессов не попадают.

set -u
cd "$(dirname "$0")" || exit 1

DOMAIN="avtozalog-krsk.ru"
FILES="index.html privacy.html consent.html terms.html tariffs.html dogovor.html docs.css submit.php robots.txt sitemap.xml og.png favicon.ico favicon.svg favicon-32.png icon-192.png apple-touch-icon.png yandex_1f64a2abd1c6a83e.html"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

bold "Выкладка $DOMAIN на Timeweb"
echo "Данные FTP — в панели Timeweb, раздел «Доступ по FTP»."
echo

read -r -p "FTP-хост (вида vh123.timeweb.ru): " FTP_HOST
FTP_HOST=$(printf '%s' "$FTP_HOST" | sed -e 's#^ftp://##' -e 's#/.*$##' -e 's/[[:space:]]//g')
[ -z "$FTP_HOST" ] && { bad "хост не указан"; exit 1; }

read -r -p "FTP-логин: " FTP_USER
[ -z "$FTP_USER" ] && { bad "логин не указан"; exit 1; }

read -r -s -p "FTP-пароль (ввод не отображается): " FTP_PASS; echo
[ -z "$FTP_PASS" ] && { bad "пароль не указан"; exit 1; }

NETRC="$TMP/netrc"
printf 'machine %s\nlogin %s\npassword %s\n' "${FTP_HOST%%:*}" "$FTP_USER" "$FTP_PASS" > "$NETRC"
chmod 600 "$NETRC"
unset FTP_PASS

ftpc() { curl -sS --netrc-file "$NETRC" $TLS "$@"; }

# ---------- подключение ----------
bold "Подключение"
connect_failed() {
  bad "не удалось подключиться:"
  sed 's/^/    /' "$TMP/err.txt"
  case "$1" in
    67) echo "    Сервер отклонил логин или пароль — сверьте их в панели Timeweb." ;;
    6)  echo "    Хост не найден — проверьте адрес в панели Timeweb." ;;
    *)  echo "    Похоже на сетевую помеху. Если включён VPN — выключите его и запустите скрипт снова:"
        echo "    хостинг в России, VPN для него не нужен, а FTP через туннель часто не проходит." ;;
  esac
  exit 1
}

TLS="--ssl-reqd"
ftpc --list-only "ftp://$FTP_HOST/" > "$TMP/root.txt" 2> "$TMP/err.txt"
rc=$?
if [ "$rc" = 0 ]; then
  ok "шифрованное соединение установлено"
elif [ "$rc" = 64 ]; then
  # 64 — сервер работает, но не поддерживает TLS. Только в этом случае
  # пробуем без шифрования; при сетевых сбоях пароль открытым текстом не шлём.
  read -r -p "  Сервер не поддерживает шифрование. Подключиться без него? [y/N]: " ANS
  case "$ANS" in
    y*|Y*|д*|Д*) ;;
    *) bad "отменено: без шифрования не подключаюсь"; exit 1 ;;
  esac
  TLS=""
  ftpc --list-only "ftp://$FTP_HOST/" > "$TMP/root.txt" 2> "$TMP/err.txt"
  rc=$?
  [ "$rc" = 0 ] || connect_failed "$rc"
  warn "работаю без шифрования"
else
  connect_failed "$rc"
fi

tr -d '\r' < "$TMP/root.txt" > "$TMP/root.clean"
if grep -qx "$DOMAIN" "$TMP/root.clean"; then
  REMOTE="$DOMAIN/public_html"
elif grep -qx "public_html" "$TMP/root.clean"; then
  REMOTE="public_html"
else
  REMOTE=""
fi

echo "  Содержимое FTP:"
sed 's/^/    · /' "$TMP/root.clean"
read -r -p "Папка сайта на сервере [${REMOTE:-корень}]: " ANS
REMOTE=${ANS:-$REMOTE}
REMOTE=${REMOTE%/}
BASE="ftp://$FTP_HOST/${REMOTE:+$REMOTE/}"

put() {
  if ftpc --ftp-create-dirs -T "$1" "$BASE$2" 2> "$TMP/err.txt"; then
    ok "$2"
  else
    bad "$2: $(tr '\n' ' ' < "$TMP/err.txt")"
    FAILED=1
  fi
}

# ---------- файлы сайта ----------
bold "Загрузка файлов в /${REMOTE}"
FAILED=0
for f in $FILES; do put "$f" "$f"; done

# Редирект на HTTPS включаем только при рабочем сертификате,
# иначе сайт откроется с ошибкой безопасности.
if curl -sS -o /dev/null -m 15 "https://$DOMAIN/robots.txt" 2>/dev/null; then
  put .htaccess .htaccess
  HTTPS_READY=1
else
  sed '/# BEGIN HTTPS/,/# END HTTPS/d' .htaccess > "$TMP/.htaccess"
  put "$TMP/.htaccess" .htaccess
  warn "сертификат для $DOMAIN пока не отвечает — редирект на HTTPS не включён"
  warn "запустите скрипт ещё раз, когда в панели сертификат станет «Активен»"
  HTTPS_READY=0
fi

# ---------- приём заявок ----------
bold "Приём заявок в Telegram"
read -r -p "Записать настройки бота на сервер? [Y/n]: " ANS
case "$ANS" in
  n*|N*|н*|Н*) warn "пропускаю — на сервере остаются прежние настройки" ;;
  *)
    # Telegram блокируют в России, поэтому канал необязателен: Enter — пропустить.
    read -r -s -p "Токен бота от @BotFather (Enter — без Telegram): " TG_TOKEN; echo
    TG_CHAT=""
    if [ -n "$TG_TOKEN" ]; then
      if ! printf '%s' "$TG_TOKEN" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]+$'; then
        bad "токен не похож на токен бота (формат 123456:ABC...)"; exit 1
      fi
      read -r -p "Ваш chat_id от @userinfobot: " TG_CHAT
      TG_CHAT=$(printf '%s' "$TG_CHAT" | tr -d '[:space:]')
      if ! printf '%s' "$TG_CHAT" | grep -Eq '^-?[0-9]+$'; then
        bad "chat_id должен состоять из цифр"; exit 1
      fi
    fi

    read -r -p "Дублировать заявки на почту (Enter — не нужно): " MAIL_TO
    MAIL_TO=$(printf '%s' "$MAIL_TO" | tr -d '[:space:]')
    if [ -n "$MAIL_TO" ] && ! printf '%s' "$MAIL_TO" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
      bad "адрес почты указан с ошибкой"; exit 1
    fi
    MAIL_FROM=""
    SMTP_HOST=""; SMTP_PORT=465; SMTP_SECURE="ssl"; SMTP_USER=""; SMTP_PASS=""
    if [ -n "$MAIL_TO" ]; then
      MAIL_FROM="info@$DOMAIN"
      echo "  Письма надёжнее доходят через SMTP-авторизацию, чем через голую отправку без неё."
      echo "  Данные — в панели хостинга, раздел «Почта» → настройки для почтовых клиентов."
      read -r -p "  SMTP-хост (Enter — пропустить, будет менее надёжная отправка): " SMTP_HOST
      SMTP_HOST=$(printf '%s' "$SMTP_HOST" | tr -d '[:space:]')
      if [ -n "$SMTP_HOST" ]; then
        read -r -p "  SMTP-порт [465]: " SMTP_PORT
        SMTP_PORT=${SMTP_PORT:-465}
        read -r -p "  Шифрование ssl/tls [ssl]: " SMTP_SECURE
        SMTP_SECURE=${SMTP_SECURE:-ssl}
        read -r -p "  SMTP-логин [$MAIL_FROM]: " SMTP_USER
        SMTP_USER=${SMTP_USER:-$MAIL_FROM}
        read -r -s -p "  SMTP-пароль (пароль от этого почтового ящика, ввод не отображается): " SMTP_PASS; echo
      fi
    fi

    # Из России Telegram часто блокируют. SMS — запасной канал, который работает всегда.
    read -r -p "SMS о заявках через sms.ru — api_id из кабинета (Enter — не нужно): " SMS_API_ID
    SMS_API_ID=$(printf '%s' "$SMS_API_ID" | tr -d '[:space:]')
    SMS_TO=""
    if [ -n "$SMS_API_ID" ]; then
      if ! printf '%s' "$SMS_API_ID" | grep -Eq '^[A-Fa-f0-9-]{20,60}$'; then
        bad "api_id не похож на ключ sms.ru"; exit 1
      fi
      read -r -p "Номер для SMS [+7 923 333-21-95]: " SMS_TO
      SMS_TO=$(printf '%s' "${SMS_TO:-+79233332195}" | tr -d '[:space:]()-')
      if ! printf '%s' "$SMS_TO" | grep -Eq '^\+?[0-9]{11}$'; then
        bad "номер должен быть в формате +79233332195"; exit 1
      fi
    fi

    TG_IPV6=false
    read -r -p "Telegram с сервера работает только по IPv6? (не знаете — Enter) [y/N]: " ANS
    case "$ANS" in y*|Y*|д*|Д*) TG_IPV6=true ;; esac

    # Токен уходит в curl через stdin, а не аргументом командной строки.
    if [ -n "$TG_TOKEN" ]; then
    curl -sS -m 15 -K - > "$TMP/tg.json" 2> "$TMP/err.txt" <<EOF
url = "https://api.telegram.org/bot$TG_TOKEN/sendMessage"
data-urlencode = "chat_id=$TG_CHAT"
data-urlencode = "text=✅ Бот подключён к сайту $DOMAIN. Сюда будут приходить заявки."
EOF
    lrc=$?
    # Заявки в Telegram отправляет сервер, а не этот компьютер. Если отсюда
    # Telegram недоступен (без VPN это обычное дело), связь проверим с сервера.
    if [ "$lrc" != 0 ]; then
      warn "с этого компьютера Telegram недоступен — проверю связь с сервера"
    elif grep -q '"ok":true' "$TMP/tg.json"; then
      ok "тестовое сообщение пришло в Telegram"
    else
      bad "Telegram отклонил настройки:"
      sed 's/^/    /' "$TMP/tg.json"
      echo "    Проверьте токен и что вы нажали «Start» в чате со своим ботом."
      exit 1
    fi
    fi

    umask 077
    cat > "$TMP/config.local.php" <<EOF
<?php
return [
    'tg_token'  => '$TG_TOKEN',
    'tg_chat'   => '$TG_CHAT',
    'tg_ipv6'   => $TG_IPV6,
    'mail_to'   => '$MAIL_TO',
    'mail_from' => '$MAIL_FROM',
    'smtp_host'   => '$SMTP_HOST',
    'smtp_port'   => $SMTP_PORT,
    'smtp_secure' => '$SMTP_SECURE',
    'smtp_user'   => '$SMTP_USER',
    'smtp_pass'   => '$SMTP_PASS',
    'sms_api_id' => '$SMS_API_ID',
    'sms_to'     => '$SMS_TO',
    'min_seconds_between' => 20,
];
EOF
    unset TG_TOKEN SMTP_PASS
    put "$TMP/config.local.php" config.local.php
    ;;
esac

# Одноразовый скрипт с случайным именем: сервер сам отправляет сообщение
# в Telegram с настройками из config.local.php, после чего файл удаляется.
TG_STATUS=unknown

# Одноразовый скрипт со случайным именем: сервер сам проверяет, до каких
# каналов уведомлений он дотягивается. После проверки файл удаляется.
server_check() {
  local name="check-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 20).php"
  cat > "$TMP/$name" <<'PHP'
<?php
ini_set('display_errors', '0');
header('Content-Type: text/plain; charset=utf-8');
$f = __DIR__ . '/config.local.php';
$cfg = is_file($f) ? require $f : [];
echo 'PHP ' . PHP_VERSION . "\n";

function tg_try($cfg, $v6) {
    if (empty($cfg['tg_token']) || empty($cfg['tg_chat'])) return 'NO_CONFIG';
    $ch = curl_init('https://api.telegram.org/bot' . $cfg['tg_token'] . '/sendMessage');
    $o = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 6,
        CURLOPT_TIMEOUT        => 12,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => [
            'chat_id' => $cfg['tg_chat'],
            'text'    => '✅ Сервер сайта связался с Telegram' . ($v6 ? ' по IPv6' : '') . ' — заявки будут приходить сюда.',
        ],
    ];
    if ($v6) $o[CURLOPT_IPRESOLVE] = CURL_IPRESOLVE_V6;
    curl_setopt_array($ch, $o);
    $b = curl_exec($ch);
    $c = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    return ($b !== false && $c === 200) ? 'OK' : ('FAIL ' . $c . ' ' . curl_error($ch));
}

$t4 = tg_try($cfg, false);
echo 'TG4 ' . $t4 . "\n";
echo 'TG6 ' . ($t4 === 'OK' ? 'SKIP' : tg_try($cfg, true)) . "\n";

function smtp_probe($host, $port, $secure, $user, $pass, $fromEmail, $to) {
    $errno = 0; $errstr = '';
    $ctx = stream_context_create(['ssl' => ['verify_peer' => true, 'verify_peer_name' => true]]);
    $fp = @stream_socket_client((($secure === 'ssl') ? 'ssl://' : 'tcp://') . $host . ':' . $port, $errno, $errstr, 12, STREAM_CLIENT_CONNECT, $ctx);
    if (!$fp) return "FAIL connect: $errstr ($errno)";
    stream_set_timeout($fp, 12);
    $r = function () use ($fp) {
        $d = ''; $c = '';
        do { $l = fgets($fp, 1000); if ($l === false) break; $d .= $l; $c = substr($l, 0, 3); } while (isset($l[3]) && $l[3] === '-');
        return [$c, trim($d)];
    };
    $w = function ($s) use ($fp) { fwrite($fp, $s . "\r\n"); };
    list($c) = $r(); if ($c !== '220') { fclose($fp); return 'FAIL greeting'; }
    $w('EHLO ' . $host); list($c) = $r(); if ($c !== '250') { fclose($fp); return 'FAIL ehlo'; }
    if ($secure === 'tls') {
        $w('STARTTLS'); list($c) = $r(); if ($c !== '220') { fclose($fp); return 'FAIL starttls'; }
        if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) { fclose($fp); return 'FAIL tls-handshake'; }
        $w('EHLO ' . $host); list($c) = $r();
    }
    $w('AUTH LOGIN'); list($c) = $r(); if ($c !== '334') { fclose($fp); return 'FAIL auth-login'; }
    $w(base64_encode($user)); list($c) = $r(); if ($c !== '334') { fclose($fp); return 'FAIL auth-user'; }
    $w(base64_encode($pass)); list($c, $resp) = $r(); if ($c !== '235') { fclose($fp); return "FAIL auth-pass: $resp"; }
    $w("MAIL FROM:<$fromEmail>"); list($c) = $r(); if ($c !== '250') { fclose($fp); return 'FAIL mail-from'; }
    $w("RCPT TO:<$to>"); list($c) = $r(); if ($c !== '250' && $c !== '251') { fclose($fp); return 'FAIL rcpt-to'; }
    $w('DATA'); list($c) = $r(); if ($c !== '354') { fclose($fp); return 'FAIL data'; }
    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $h  = 'From: ' . $utf('Сайт') . " <$fromEmail>\r\nTo: <$to>\r\nSubject: " . $utf('Проверка уведомлений с сайта') . "\r\nDate: " . date('r') . "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n";
    $body = "Это проверка почтовых уведомлений с сайта.\r\nЕсли письмо пришло - заявки тоже будут приходить сюда.";
    $w($h . "\r\n" . $body . "\r\n."); list($c) = $r(); $w('QUIT'); fclose($fp);
    return $c === '250' ? 'SENT' : "FAIL send:$c";
}

if (!empty($cfg['mail_to']) && !empty($cfg['smtp_host']) && !empty($cfg['smtp_user']) && !empty($cfg['smtp_pass'])) {
    echo 'MAIL ' . smtp_probe($cfg['smtp_host'], $cfg['smtp_port'] ?? 465, $cfg['smtp_secure'] ?? 'ssl', $cfg['smtp_user'], $cfg['smtp_pass'], $cfg['mail_from'] ?: $cfg['smtp_user'], $cfg['mail_to']) . "\n";
} elseif (!empty($cfg['mail_to']) && !empty($cfg['mail_from'])) {
    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $h  = 'From: ' . $utf('Сайт') . ' <' . $cfg['mail_from'] . ">\r\n";
    $h .= "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n";
    $body = "Это проверка почтовых уведомлений с сайта.\nЕсли письмо пришло — заявки тоже будут приходить сюда.";
    echo 'MAIL ' . (@mail($cfg['mail_to'], $utf('Проверка уведомлений с сайта'), $body, $h) ? 'SENT (без SMTP-авторизации, менее надёжно)' : 'FAIL') . "\n";
} else {
    echo "MAIL SKIP\n";
}
echo 'SMS ' . (!empty($cfg['sms_api_id']) && !empty($cfg['sms_to']) ? 'CONFIGURED' : 'SKIP') . "\n";
PHP
  if ! ftpc --ftp-create-dirs -T "$TMP/$name" "$BASE$name" 2> "$TMP/err.txt"; then
    bad "не удалось загрузить проверку каналов уведомлений"
    return
  fi
  local out
  out=$(curl -s -m 60 "$URL/$name")
  ftpc -o /dev/null --list-only -Q "DELE ${REMOTE:+$REMOTE/}$name" "ftp://$FTP_HOST/" 2> /dev/null \
    || warn "удалите вручную в файловом менеджере: $name"

  case "$out" in
    PHP*) ;;
    *) bad "проверка вернула неожиданный ответ: $(printf '%s' "$out" | head -c 150)"; return ;;
  esac

  printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
      "PHP "*)          ok "на сервере ${line}" ;;
      "TG4 OK")         ok "Telegram доступен — заявки будут приходить в бот" ;;
      "TG4 NO_CONFIG")  warn "настройки бота на сервере отсутствуют" ;;
      "TG6 OK")         ok "Telegram доступен по IPv6 — включите 'tg_ipv6' => true при следующем запуске" ;;
      "TG6 SKIP"|"TG6 NO_CONFIG") ;;
      "TG4 FAIL"*)      warn "Telegram по IPv4 недоступен: ${line#TG4 FAIL }" ;;
      "TG6 FAIL"*)      bad  "Telegram недоступен и по IPv6 — нужен другой канал уведомлений" ;;
      "MAIL SENT"*)     ok "письмо на почту отправлено — проверьте ящик, в том числе «Спам»: ${line#MAIL SENT}" ;;
      "MAIL FAIL"*)     bad "сервер не смог отправить письмо: ${line#MAIL FAIL}" ;;
      "MAIL SKIP")      warn "почта не настроена" ;;
      "SMS CONFIGURED") ok "SMS-уведомления подключены" ;;
    esac
  done

  case "$out" in
    *"TG4 OK"*|*"TG6 OK"*) TG_STATUS=ok ;;
  esac
}

# ---------- проверка ----------
bold "Проверка сайта"
if [ "$HTTPS_READY" = 1 ]; then SCHEME=https; else SCHEME=http; fi
URL="$SCHEME://$DOMAIN"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$URL/" 2>/dev/null)
if [ "$code" = 200 ]; then
  ok "$URL открывается"

  for p in privacy.html tariffs.html dogovor.html; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$URL/$p")
    [ "$c" = 200 ] && ok "$p" || bad "$p отвечает $c"
  done

  if curl -s -m 15 "$URL/config.local.php" | grep -q 'tg_token\|api\.telegram'; then
    bad "config.local.php читается снаружи — не запускайте рекламу, сообщите мне"
  else
    ok "настройки бота снаружи не читаются"
  fi

  if [ "$HTTPS_READY" = 1 ]; then
    r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -m 15 "http://$DOMAIN/")
    case "$r" in 301*https*) ok "http → https перенаправляется" ;; *) warn "редирект на https не сработал: $r" ;; esac
  fi

  server_check

  read -r -p "Отправить тестовую заявку через форму сайта? [Y/n]: " ANS
  case "$ANS" in
    n*|N*|н*|Н*) ;;
    *)
      res=$(curl -s -m 20 "$URL/submit.php" \
        --data-urlencode "name=Тестовая заявка" \
        --data-urlencode "phone=+7 (900) 000-00-00" \
        --data-urlencode "car=Проверка после выкладки" \
        --data-urlencode "amount=300 000 — 700 000 ₽" \
        --data-urlencode "consent=1" \
        --data-urlencode "page=/deploy-check")
      case "$res" in
        *'"ok":true'*)
          if [ "$TG_STATUS" = ok ]; then ok "заявка принята — проверьте Telegram"
          else ok "заявка принята и записана в журнал на сервере"; fi ;;
        *) bad "обработчик ответил: $res" ;;
      esac
      ;;
  esac

  # Строки журнала начинаются с даты в кавычках — если такое отдаётся наружу, это утечка.
  if curl -s -m 15 "$URL/leads.csv" | head -c 300 | grep -q '^"20[0-9][0-9]-'; then
    bad "журнал заявок leads.csv доступен из браузера — не запускайте рекламу, сообщите мне"
  else
    ok "журнал заявок снаружи недоступен"
  fi
else
  warn "$URL пока не открывается (код $code)"
  warn "проверьте статус домена в панели Timeweb → «Домены»: он должен быть делегирован"
  warn "связь сервера с Telegram и тестовую заявку проверю, когда сайт откроется"
fi

bold "Готово"
[ "$FAILED" = 1 ] && bad "часть файлов не загрузилась — см. выше" || ok "все файлы на месте"
[ "$HTTPS_READY" = 0 ] && warn "после выпуска сертификата запустите: bash deploy.sh"
echo
