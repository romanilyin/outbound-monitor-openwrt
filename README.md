# Outbound Monitor для OpenWrt

Лёгкий монитор VPN-ключей из групп `urltest` sing-box/podkop. Каждые 5 минут
проверяет каждый ключ отдельно через уже включённый Clash API.

LuCI: **Статус → Outbound Monitor** — `/cgi-bin/luci/admin/status/outbound-monitor`.

- Отдельные SVG-графики: задержка HTTP в мс, красные точки **−10** при отказе.
- Диапазоны 1 час / 6 часов / сутки / 7 дней; просмотр значения мышью, касанием
  и стрелками клавиатуры, экспорт выбранного периода в JSON/CSV.
- Доля успешных проб, медиана задержки, последняя успешная проверка.
- После 3 последовательных отказов — рекомендация проверить или заменить ключ.
- Отдельный статус для ошибок API, отсутствующих и устаревших измерений.
- Автообнаружение вложенных URLTest/selector-групп; заменённые ключи уходят в архив.
  Отпечаток вычисляется из настроек outbound, поэтому замена пароля/UUID отделяет
  новую историю даже при сохранении имени. Смена иных параметров outbound тоже
  создаёт новую историю.

Это HTTP-задержка через VPN, **не ICMP-пинг**. Отказ означает невозможность
проверить выбранный HTTPS-адрес через ключ в этот момент. Общий сбой интернета,
DNS или тестового сайта также может дать отказы: это не доказательство истечения
срока ключа. Проценты относятся к дискретным пробам, не к непрерывному uptime.

## Нагрузка и хранение

Без базы данных, Node.js, Python, RRD, сторонней библиотеки графиков или отдельного
веб-сервера **на роутере**. Используются уже установленные LuCI, ucode, curl и procd.
Между проверками остаются shell и `sleep`; ucode/curl запускаются только на время
пробы. Запросы последовательные, максимум 32 текущих ключа и 32 архивных.

История хранится только в `/tmp/outbound-monitor/state.json` (RAM), максимум 7 дней.
При 3 ключах и интервале 300 секунд это примерно 6050 коротких записей, обычно
менее 200 КБ JSON. Есть ограничение возраста и количества записей.
История **исчезает при перезагрузке**; выгружайте JSON/CSV при необходимости.
Постоянных записей статистики во флеш нет. Служба автоматически стартует при загрузке.

Плагин не меняет настройки podkop, sing-box, сети, firewall, DNS или существующий
cron и не отправляет команды выбора ключа. Использует только GET `/proxies` и `/proxies/{tag}/delay`. Сам sing-box при
такой пробе обновляет внутреннюю историю задержки, как при ручном тесте в dashboard;
Эти результаты используются автоматикой URLTest при выборе VPN и могут сдвигать
её собственную проверку: это активный монитор, а не пассивное чтение статистики.
На тестовом роутере адрес проверки совпадает с настроенным в URLTest.
Ключи, UUID, пароли и API-secret не возвращаются в LuCI и не записываются в историю.
API-secret передаётся curl через временный файл с правами 0600 в каталоге 0700.
Страница доступна в существующей авторизованной LuCI; новые порты не открываются.

## Установка без SDK (OpenWrt с opkg или apk)

На компьютере с Python 3:

```sh
python scripts/make-bundle.py
scp -O dist/outbound-monitor-0.1.0.tar.gz root@ROUTER:/tmp/
```

На роутере:

```sh
mkdir -p /tmp/outbound-monitor-install
tar -xzf /tmp/outbound-monitor-0.1.0.tar.gz -C /tmp/outbound-monitor-install
sh /tmp/outbound-monitor-install/install.sh
```

Это установка файлов из исходников; она не регистрирует пакет в opkg/apk.
Установщик сохраняет существующий `/etc/config/outbound-monitor`, управляет только
собственной службой и вызывает `rpcd reload` (SIGHUP) для регистрации своего RPC.
VPN-службы не перезапускаются. Если LuCI была открыта, обновите страницу.
Установщик ничего не скачивает и при отсутствующих зависимостях прекращает работу.

Зависимости: `ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-digest`, `curl`,
`flock`, `luci-base`, `rpcd-mod-ucode`. Для HTTPS-проб TLS выполняет сам sing-box.

## Пакеты OpenWrt SDK

Обе папки содержат Makefile для SDK/buildroot своей версии OpenWrt:

```sh
cp -r outbound-monitor luci-app-outbound-monitor "$SDK/package/"
cd "$SDK"
make defconfig
make package/outbound-monitor/compile package/luci-app-outbound-monitor/compile V=s
```

Архитектура пакетов `all`; формат IPK или APK определяется SDK. SDK-сборка
не нужна для установки архива выше. Используйте пакетную установку для управления
через opkg/apk и сохранения списка пакетов при обновлении прошивки.

## Настройки и команды

`/etc/config/outbound-monitor` содержит только настройки этого плагина:

| Поле | По умолчанию | Допустимо |
| --- | --- | --- |
| enabled | 1 | 0 / 1 |
| interval | 300 секунд | 60–86400 |
| retention_days | 7 | 1–7 |
| timeout | 8 секунд | 1–30 |
| test_url | https://www.gstatic.com/generate_204 | HTTPS-адрес |
| sing_box_config | /etc/sing-box/config.json | путь к действующему JSON sing-box |

После изменения настроек: `/etc/init.d/outbound-monitor restart`.
Сохранённая API-привязка читается из конфигурации sing-box; wildcard-адреса
`0.0.0.0` и `[::]` заменяются loopback. Если API отключён, плагин покажет ошибку;
он не включает API самостоятельно. Поддерживаются конфиги с одиночным JSON-файлом.
При изменении outbounds на диске плагин ожидает новый процесс sing-box, чтобы не
приписать старые измерения новым ключам. При первой привязке и при каждом новом
процессе предполагается, что указанный JSON соответствует работающему sing-box;
изменения отслеживаются по хешу outbounds и PID/времени запуска процесса.
API не раскрывает загруженные пароли/UUID, поэтому это допущение нельзя проверить
через него. Сохраняйте конфигурацию и применяйте её обычным способом через podkop:
ручная правка JSON после рестарта до очередного опроса может нарушить привязку.

```sh
outbound-monitor status 24       # история за сутки, JSON
outbound-monitor collect         # дополнительная проба, защищена flock от наложений
/etc/init.d/outbound-monitor stop
/etc/init.d/outbound-monitor start
```

При большом числе ключей сумма тайм-аутов может превысить интервал; циклы не
накладываются, следующий начнётся после завершения предыдущего. Пропуски отражаются
на графике. Смена часов назад удаляет будущие точки из текущего окна.

## Проверки при разработке

```sh
node --test --test-isolation=none tests/ui.test.cjs
ucode tests/core.uc
python scripts/check-router.py --env /path/to/external.env
```

`check-router.py` требует `paramiko` на компьютере разработчика. Он загружает
исходники в `/tmp/outbound-monitor-check`, запускает изолированные тесты и проверку
синтаксиса, затем прогоняет HTTP-сценарии через локальную заглушку curl;
ничего не устанавливает и не перезапускает. Файл доступа должен иметь
`ROUTER_IP` и `ROUTER_PASSWORD`; необязательны `ROUTER_USER` и `ROUTER_PORT`.
Не копируйте `.env` в репозиторий. SSH host key сохраняется локально в `.local/known_hosts`.

## Удаление установки из архива

```sh
/etc/init.d/outbound-monitor stop
/etc/init.d/outbound-monitor disable
rm -f /etc/init.d/outbound-monitor /usr/bin/outbound-monitor
rm -f /usr/share/outbound-monitor/core.uc /usr/share/outbound-monitor/main.uc
rm -f /usr/share/rpcd/ucode/outbound-monitor.uc
rm -f /usr/share/rpcd/acl.d/luci-app-outbound-monitor.json
rm -f /usr/share/luci/menu.d/luci-app-outbound-monitor.json
rm -f /www/luci-static/resources/view/outbound-monitor/status.js
rm -f /www/luci-static/resources/outbound-monitor/style.css
/etc/init.d/rpcd reload
```

Настройки `/etc/config/outbound-monitor` и накопленная история при этом остаются.
Удалите их отдельно, если они больше не нужны. При пакетной установке используйте
штатное удаление `luci-app-outbound-monitor` и `outbound-monitor` через opkg/apk.

API основан на [Clash API sing-box](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
и [реализации индивидуального delay endpoint](https://github.com/SagerNet/sing-box/blob/v1.12.0/experimental/clashapi/proxies.go).
