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
# yandex_XXXXXXXXXXXXXXXX.html — файл-подтверждение прав в Яндекс.Вебмастере.
# Для этого домена его ещё нет: заведите сайт в Вебмастере, скачайте файл,
# положите его рядом с index.html и добавьте его имя в список FILES ниже.
FILES="index.html privacy.html consent.html terms.html tariffs.html dogovor.html docs.css send.php robots.txt sitemap.xml og.png favicon.ico favicon.svg favicon-32.png icon-192.png apple-touch-icon.png"

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
    [ -n "$MAIL_TO" ] && MAIL_FROM="info@$DOMAIN"

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
    'sms_api_id' => '$SMS_API_ID',
    'sms_to'     => '$SMS_TO',
    'min_seconds_between' => 20,
];
EOF
    unset TG_TOKEN
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

if (!empty($cfg['mail_to']) && !empty($cfg['mail_from'])) {
    $utf = function ($s) { return '=?UTF-8?B?' . base64_encode($s) . '?='; };
    $h  = 'From: ' . $utf('Сайт') . ' <' . $cfg['mail_from'] . ">\r\n";
    $h .= "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n";
    $body = "Это проверка почтовых уведомлений с сайта.\nЕсли письмо пришло — заявки тоже будут приходить сюда.";
    echo 'MAIL ' . (@mail($cfg['mail_to'], $utf('Проверка уведомлений с сайта'), $body, $h) ? 'SENT' : 'FAIL') . "\n";
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
      "MAIL SENT")      ok "письмо на почту отправлено — проверьте ящик, в том числе «Спам»" ;;
      "MAIL FAIL")      bad "сервер не смог отправить письмо" ;;
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
      res=$(curl -s -m 20 "$URL/send.php" \
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
