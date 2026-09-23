## English

Lightweight availability and HTTP latency monitoring for individual sing-box/podkop URLTest keys.

- Stable SHA-256 chart IDs from credential-bearing outbound configuration without the top-level tag: reordering preserves history and changed credentials create a new history. The observed podkop link hash is saved separately as metadata, never used to assign history; raw links are not stored.
- LuCI comparison table with VPN failure percentage, mean delay, population variance and standard deviation. Latency metrics use successful samples only; unknown and suspected common network failures are excluded.
- LuCI charts with red VPN failures and blue suspected common network failures at **−10**, 1h/6h/24h/7d history and JSON/CSV export.
- Two direct HTTPS controls distinguish the pattern where both controls and all VPN probes fail; a surviving VPN probe produces a mixed result. Blue failures do not count against a key's failure rate or replacement recommendation.
- Optional DNS diagnosis through an already installed IPRegion after both direct controls fail, including mixed results. Enabled by `dns_check=1`, using available IPRegion resolvers/transports (UDP/TCP and DoT/DoH where supported), isolated runtime state, a two-second request timeout, no retries and a 25-second cap. No IPRegion dependency or configuration changes.
- Latest DNS check time and compact resolver results; JSON exports include at most 128 detailed network events within the configured retention period (up to seven days).
- English and Russian interface and documentation.
- Button-triggered GitHub update checks and package installation with SHA-256 verification.
- APK packages for OpenWrt 25.12; IPK packages for OpenWrt 24.10. All packages contain architecture-independent scripts/UI.
- Preserves monitoring settings, RAM history and service enabled/running state during updates.

Use `install.sh` from the repository for automatic package-manager detection. History lives in RAM and resets on reboot. Direct controls may still depend on the configured DNS resolver or a system default route through a VPN; IPRegion also uses the router's route. These signals do not prove ISP fault, DNS tampering or provider responsibility. See README for installation, active URLTest side effects and the assumption that JSON matches the running sing-box process. Hardware validation scope is recorded separately in `docs/VERIFICATION.md`.

## Русский

Лёгкий монитор доступности и HTTP-задержки каждого ключа в URLTest-группах sing-box/podkop.

- Устойчивые SHA-256 ID графиков по конфигурации outbound с учётными данными без верхнеуровневого тега: перестановка сохраняет историю, а изменение учётных данных создаёт новую. Наблюдаемый хеш ссылки podkop сохраняется отдельно как метаданные и не назначает историю; исходные ссылки не сохраняются.
- Таблица сравнения LuCI с процентом отказов VPN, средней задержкой, генеральной дисперсией и стандартным отклонением. Метрики задержки учитывают только успешные пробы; неизвестные и вероятные общие сетевые сбои исключаются.
- Графики LuCI с красными отказами VPN и синими вероятными общими сетевыми сбоями на **−10**, история 1ч/6ч/24ч/7д и экспорт JSON/CSV.
- Две прямые HTTPS-пробы выделяют одновременный отказ обеих контрольных и всех VPN-проверок; при успешной VPN-пробе результат смешанный. Синие отказы не ухудшают процент отказов ключа и не вызывают рекомендацию заменить его.
- Необязательная DNS-диагностика через уже установленный IPRegion при отказе обеих прямых проверок, в том числе при смешанном результате. Включается `dns_check=1`: доступные резолверы/транспорты IPRegion (UDP/TCP и DoT/DoH при поддержке), отдельные временные данные, тайм-аут запроса две секунды, без повторов, общий лимит 25 секунд. IPRegion не добавляется в зависимости, его настройки не меняются.
- Время последней DNS-проверки и краткие результаты резолверов; JSON-экспорт включает не более 128 подробных сетевых событий за выбранный срок хранения (до семи дней).
- Русский и английский интерфейс и документация.
- Проверка обновлений и установка из GitHub по кнопке с проверкой SHA-256.
- APK для OpenWrt 25.12 и IPK для OpenWrt 24.10; скрипты и интерфейс не зависят от архитектуры процессора.
- При обновлении сохраняются настройки, история в RAM и состояние службы мониторинга.

`install.sh` сам определяет пакетный менеджер. История хранится в RAM и очищается после перезагрузки. Прямые проверки могут зависеть от настроенного DNS-резолвера или системного маршрута через VPN; IPRegion также использует маршрут роутера. Эти признаки не доказывают неисправность провайдера, подмену DNS или ответственность конкретного оператора. Установка, влияние активных проб на URLTest и допущение о соответствии JSON работающему sing-box описаны в README. Объём проверки на оборудовании отдельно указан в `docs/VERIFICATION.md`.
