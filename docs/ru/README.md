# Mullvad VLESS Bridge: установка и использование

Неофициальный скрипт для VPS. Он поднимает VLESS Reality сервер и направляет исходящий трафик через Mullvad.

> Проект не связан официально с Mullvad VPN, 3x-ui, Xray, Happ или VPS-провайдерами.

## Лицензия

Проект распространяется под [GNU Affero General Public License v3.0](../../LICENSE).

Коммерческое использование разрешено только на условиях AGPLv3. Измененные версии должны распространяться под той же лицензией и предоставлять пользователям исходный код.

## Что получится

После установки у тебя будет:

- ссылка подписки для Happ или другого приложения с поддержкой VLESS Reality;
- два узла в одной подписке:
  - `RU - Mullvad - Reality` - основной вариант для сетей с жесткими ограничениями;
  - `Global - Mullvad - Reality` - запасной или основной вариант для обычных сетей;
- два готовых профиля Happ:
  - [`profiles/happ/ru.json`](../../profiles/happ/ru.json);
  - [`profiles/happ/global.json`](../../profiles/happ/global.json);
- исходящий трафик через Mullvad, а не через IP VPS;
- включенные функции Mullvad: DAITA, Multihop, Quantum Resistance и Lockdown Mode.

## Как это работает

```text
Телефон или компьютер
  -> VLESS Reality
  -> твой VPS
  -> Mullvad на VPS
  -> интернет
```

Пользователь подключается не к Mullvad напрямую, а к твоему VPS. На VPS работает VLESS Reality, а дальше трафик уходит через Mullvad.

Mullvad запускается как обычная служба на сервере. Поэтому сохраняются DAITA, Multihop, Quantum Resistance и Lockdown Mode.

Чтобы сервер не потерял SSH, VLESS и ссылку подписки после включения Lockdown Mode, скрипт добавляет отдельные правила только для входящих служебных портов. Пользовательский трафик через эти правила не выводится и идет через Mullvad.

## Требования

- свежий VPS с Debian 12 или Ubuntu 24.04;
- доступ по SSH под `root`;
- публичный IPv4;
- активный аккаунт Mullvad;
- открытые TCP-порты у VPS-провайдера:
  - `22` для SSH;
  - `80` для выпуска сертификата;
  - `443` для узла `RU`;
  - `8443` для узла `Global`;
  - `2096` для ссылки подписки.

> Не запускай скрипт на сервере с важными рабочими настройками. Он меняет сетевой экран, DNS, SSH, systemd, Mullvad и 3x-ui/Xray.

Если в `/root/.ssh/authorized_keys` уже есть SSH-ключи, скрипт отключит вход по паролю для `root`. Если ключей нет, вход по паролю останется включенным, чтобы ты не потерял доступ к свежему VPS.

## Установка

Есть два варианта установки.

### Вариант 1: из опубликованного GitHub-репозитория

Зайди на VPS под `root`:

```bash
ssh root@VPS_IP
```

Замени `VPS_IP` на IP-адрес своего сервера.

На VPS выполни:

```bash
curl -fsSLo /root/install-mullvad-vless-bridge.sh \
  https://raw.githubusercontent.com/Wiredless-wq/mullvad-vless-bridge/main/ops/scripts/install-mullvad-vless-bridge.sh
chmod +x /root/install-mullvad-vless-bridge.sh
/root/install-mullvad-vless-bridge.sh
```

Эта команда скачивает скрипт из репозитория `Wiredless-wq/mullvad-vless-bridge`.

### Вариант 2: передать локальный файл на сервер

Если репозиторий еще не опубликован, передай скрипт с компьютера на VPS.

На своем компьютере открой папку проекта:

```bash
cd /home/mark/Documents/Dev_MullvadVless/Mullvad-VLESS-GitHub
```

Скопируй скрипт на сервер:

```bash
scp -P 22 ops/scripts/install-mullvad-vless-bridge.sh root@VPS_IP:/root/
```

Если SSH пишет `REMOTE HOST IDENTIFICATION HAS CHANGED`, а ты точно переустановил этот VPS сам, удали старый ключ:

```bash
ssh-keygen -R VPS_IP
```

После этого повтори `scp`.

Зайди на сервер:

```bash
ssh root@VPS_IP
```

Запусти установку:

```bash
chmod +x /root/install-mullvad-vless-bridge.sh
/root/install-mullvad-vless-bridge.sh
```

Скрипт спросит номер аккаунта Mullvad:

```text
Mullvad account number:
```

В конце он покажет ссылку подписки:

```text
https://DOMAIN:2096/sub/SUB_ID
```

Сохрани эту ссылку. Ее нужно импортировать в Happ или другое приложение с VLESS Reality.

Если предыдущая установка прервалась на середине и нужно начать заново, запусти:

```bash
RESET_INSTALL=1 /root/install-mullvad-vless-bridge.sh
```

## Подключение в Happ

1. Открой Happ.
2. Добавь подписку по ссылке, которую показал скрипт.
3. В подписке появятся два узла: `RU - Mullvad - Reality` и `Global - Mullvad - Reality`.

## Профили Happ

Профили лежат отдельно от ссылки подписки. Они настраивают DNS и маршрутизацию внутри Happ.

Как использовать:

1. Импортируй ссылку подписки.
2. Импортируй нужный профиль Happ.
3. Выбери узел `RU - Mullvad - Reality` или `Global - Mullvad - Reality`.
4. Включи VPN в Happ.

Для глобального профиля используется Mullvad DNS over HTTPS: `https://dns.mullvad.net/dns-query`. Адрес и IP указаны в официальной справке Mullvad: <https://mullvad.net/en/help/dns-over-https-and-dns-over-tls>.

## Проверка

На VPS:

```bash
mullvad status -v
systemctl is-active x-ui mullvad-daemon mullvad-connect mullvad-vps-bypass
ss -tlnp | grep -E ':(22|443|8443|2096)'
curl -s "https://DOMAIN:2096/sub/SUB_ID" | base64 -d
```

Для теста после подключения открой 

```text
https://am.i.mullvad.net/connected
```

## Повторный запуск

Если установка прервалась, исправь ошибку и запусти тот же файл еще раз:

```bash
/root/install-mullvad-vless-bridge.sh
```

Скрипт хранит состояние здесь:

```text
/var/lib/mullvad-vless-bridge/install.env
```

Он переиспользует уже созданные ключи, UUID и ссылку подписки.

Чтобы пересоздать все заново:

```bash
RESET_INSTALL=1 /root/install-mullvad-vless-bridge.sh
```

## Логи / бэкапы

```text
/var/log/mullvad-vless-install.log
/var/lib/mullvad-vless-bridge/install.env
/root/mullvad-vless-installer-backups/
```


## Ограничения

- Один VPS - один мост. Если IP VPS заблокировали, нужен новый VPS.
