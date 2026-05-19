### План: добавить AWS Transcribe (HTTP/2) в Rust S2T через динамическую диспетчеризацию

#### Summary
- Внедрить AWS-провайдер в `s2t-core-rust`, не удаляя Google и local Whisper.
- Оставить Google путь как есть: `gRPC + HTTP/3 + Envoy`.
- Для AWS использовать **HTTP/2** (через AWS SDK), без Envoy и без fallback-цепочек.
- Выбор провайдера — через runtime dynamic dispatch (`trait object`) и env.

#### Key changes
- Ввести контракт провайдера:
  - `TranscribeProvider` trait с единым async-методом транскриба из аудиопотока.
  - Реализации: `GoogleProvider` (текущий), `LocalProvider`, `AwsProvider`.
- Добавить фабрику/диспетчер:
  - `S2T_ASR_PROVIDER=google|local|aws`.
  - Невалидный provider → явная ошибка старта.
- AWS provider (HTTP/2):
  - `aws-config` + `aws-sdk-transcribestreaming`.
  - Стандартная credential chain, поддержка `AWS_PROFILE=frank`.
  - Параметры по умолчанию: `ru-RU`, streaming transcription.
  - Сбор финального текста из результатов стрима.
- Конфиг и запуск:
  - Убрать хардкод project/location из `main.rs` в env-конфиг.
  - Убедиться, что `s2t-rust.service` подхватывает env-файлы (`/etc/s2t/s2t.env`, `~/.config/s2t/*.env`) для выбора провайдера и AWS-настроек.
- Совместимость:
  - Не менять X11 вставку/буферы в этом таске.
  - Не менять legacy `controller.sh` в этом этапе.

#### Public interfaces / env
- Расширить `S2T_ASR_PROVIDER` значением `aws`.
- Поддержать AWS env:
  - `AWS_PROFILE` (например `frank`)
  - `AWS_REGION` / `AWS_DEFAULT_REGION`
  - `S2T_AWS_LANGUAGE_CODE` (default `ru-RU`)
- Существующие Google/local env оставить рабочими.

#### Test plan
- Unit:
  - Выбор провайдера по env.
  - Ошибки конфигурации (unknown provider, отсутствующий регион/креды при `aws`).
- Integration/smoke:
  - `provider=google`: текущий flow без регрессий.
  - `provider=local`: успешный запрос к whisper-server и возврат текста.
  - `provider=aws`: успешный HTTP/2 streaming; отдельные проверки на auth/network errors.
- Runtime:
  - Автовставка и ручная вставка работают как до изменений.
  - Переключение provider через env без правок кода.

#### Assumptions
- Этап 1 покрывает только Rust runtime.
- AWS берём как единственный managed STT путь в AWS для RU-кейса.
- По качеству RU “Google vs AWS” финально сравниваем отдельным A/B прогоном на твоих реальных диктовках.
