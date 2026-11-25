# Сборка GKI и перепаковка vendor_dlkm

[English (default)](README.md)

Скрипты собирают Android GKI через Kbuild, позволяют явно выбрать нужные `.ko` и заменяют существующие модули в образе ext4 `vendor_dlkm`. Они не подключаются к устройству, не прошивают разделы и не подписывают образы.

| Скрипт | Назначение |
| --- | --- |
| `build-kernel.sh` | Настройка и сборка `Image` и модулей ядра, список настроенных модулей, сборка выбранных встроенных в дерево или внешних модулей. |
| `build-qcom-audio.sh` | Сборка пакета аудиодрайверов Qualcomm с выгрузкой только выбранных SPF/LPASS `.ko` и `Module.symvers`. |
| `repack-vendor-dlkm.py` | Список существующих модулей или замена выбранных `.ko` в новом raw ext4-образе. |

## Требования

- **Сборка:** Linux, Bash 4+, GNU coreutils, GNU Make, `rsync` для внешних модулей и соответствующий ветке ядра LLVM (Clang, LLD и утилиты LLVM). Для ядра также нужны обычные зависимости: как правило, `bc`, `bison`, `flex`, библиотеки разработки OpenSSL и ELF, а для BTF — `pahole`. Используйте ревизию Android LLVM, указанную в исходниках.
- **Перепаковка:** Python 3.8+, `e2fsprogs` (`debugfs`, `e2fsck`), `kmod` (`modinfo`, `modprobe`) и `readelf` из `binutils`. Для sparse-входа нужен `simg2img`, для `--strip-debug` — `llvm-strip`. Root и монтирование не нужны. Используйте доверенные исходники модулей и образы.
- Для Kbuild используйте пути без пробелов. Для сборки модулей `--dist` должен указывать на **новый** каталог. При выборе модулей из дерева ядра выходной каталог копируется в `$TMPDIR` (по умолчанию `/tmp`); если reflink недоступен, потребуется место для полной копии. Не запускайте параллельные сборки с одним выходным деревом.

Запускайте примеры из `my-build-scripts`. Подставьте пути, ветку и toolchain для своего устройства:

```bash
KERNEL_SRC=../android_kernel_xiaomi_sm8635
LLVM_BIN=../clang-r547379/bin
KERNEL_OUT="$PWD/out/gki"
```

## 1. Сборка GKI

```bash
./build-kernel.sh kernel \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --defconfig gki_defconfig --jobs 8 \
  --dist "$PWD/dist/gki"
```

- По умолчанию используются `ARCH=arm64`, `gki_defconfig` и по одному заданию на логическое ядро CPU. Режим `kernel` собирает `Image` и все настроенные модули из дерева ядра. При указании `--dist` туда копируются `Image` и `Module.symvers`, а `.ko` остаются в `--kernel-out`.
- Вместо `--defconfig` можно передать готовый конфиг через `--config FILE`, а для повторной сборки с конфигом из выходного дерева — `--reuse-config`. Опцию `--fragment FILE` можно повторять: фрагменты применяются по порядку. Добавьте `--configure-only` (без `--dist`), чтобы до компиляции проверить, что Kconfig сохранил нужные настройки. `--dry-run` показывает команды без создания артефактов.
- Это прямая сборка через Kbuild, а не замена Kleaf/Bazel, сертификации или штатной упаковке Android для устройства. `Image` — **не** `boot.img`. Для последующей сборки модулей сохраняйте выходное дерево вместе с точной ревизией исходников, конфигурацией и toolchain.

## 2. Выбор любого модуля Kbuild

Укажите точное имя `.ko` без каталога через `--module NAME` (с расширением или без) либо точный путь через `--target PATH.ko`. Обе опции можно повторять. Если имена совпадают у нескольких модулей, выберите нужный по пути через `--target`. Список драйверов не зашит в скрипт: доступные модули определяет Kbuild. Встроенный в ядро драйвер не является `.ko`, а для пакетов, требующих Kleaf/DDK или другой vendor-системы сборки, нужна соответствующая система.

### Модуль из дерева ядра

```bash
./build-kernel.sh list --kernel-out "$KERNEL_OUT"
./build-kernel.sh in-tree \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --module cfg80211 --module rfkill \
  --dist "$PWD/dist/cfg80211"
```

Выберите имя или путь из списка. Опция драйвера в Kconfig должна быть `m`, а не `y`; при необходимости добавьте фрагмент и пересоберите GKI. Если modpost не находит символы другого модуля из дерева ядра, добавьте его `.ko` как ещё один `--target` либо используйте `--build-package`: он собирает весь набор, но выгружает только выбранные файлы. Сборка выполняется во временной копии выходного дерева и не заменяет исходные `Module.symvers` и `modules.order`. `cfg80211` — инфраструктура Wi-Fi в ядре, а не vendor-драйвер WLAN.

### Внешний модуль Kbuild

```bash
./build-kernel.sh external \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --external-root /path/to/vendor-modules \
  --package drivers/my-driver --module my_driver \
  --dist "$PWD/dist/my-driver"
```

`--package` выбирает каталог с `Kbuild` или `Makefile`; его можно опустить, если пакет в корне. `--module` собирает пакет и находит нужный `.ko` в полученном `modules.order`. Если путь относительно пакета известен, `--target` позволяет попробовать собрать только эту цель. Если отдельные цели не работают, добавьте к `--target` опцию `--build-package`. `--all` вместо выбора собирает и выгружает весь пакет. Передавайте таблицы символов соответствующих сборок зависимостей через `--symvers FILE` (можно повторять). Для переменных vendor Kbuild используйте `--set NAME=VALUE`: `@work@` подставляет путь к копии исходников, `@kernel@` — путь к дереву ядра. В исходный каталог внешних модулей результаты сборки не записываются.

### Vendor-драйвер WLAN Qualcomm (Poco F6 / Peridot)

В штатном образе Peridot драйвер называется `qca_cld3_qca6750.ko`, а не `wlan.ko`. Используется та же общая команда `external`: сначала соберите пакет WLAN Platform для получения таблицы символов, затем выберите сам драйвер по имени. Опции ниже соответствуют профилю QCA6750 в этих vendor-исходниках; у других чипов и веток могут быть другие профили и зависимости. Укажите новые выходные каталоги.

```bash
VENDOR_ROOT=../android_kernel_xiaomi_sm8635-modules/qcom/opensource
PERIDOT_OUT=../out/peridot-nosig/kernel
wlan_build=(./build-kernel.sh external
  --kernel-src "$KERNEL_SRC" --kernel-out "$PERIDOT_OUT"
  --llvm-bin "$LLVM_BIN" --external-root "$VENDOR_ROOT" --jobs 6)

"${wlan_build[@]}" --package wlan/platform --all \
  --set 'WLAN_PLATFORM_ROOT=@work@/wlan/platform' \
  --dist "$PWD/dist/peridot-wlan-platform"

"${wlan_build[@]}" --package wlan/qcacld-3.0 --module qca_cld3_qca6750 \
  --set 'WLAN_ROOT=@work@/wlan/qcacld-3.0' \
  --set MODNAME=qca_cld3_qca6750 --set CONFIG_QCA_CLD_WLAN=m \
  --set WLAN_PROFILE=qca6750 --set DYNAMIC_SINGLE_CHIP=qca6750 --set DEVNAME=qca6750 \
  --set CONFIG_IPA_OUT_OF_TREE=y --set CONFIG_QCA_WIFI_ISOC=0 --set CONFIG_QCA_WIFI_2_0=1 \
  --symvers "$PWD/dist/peridot-wlan-platform/Module.symvers" \
  --dist "$PWD/dist/peridot-wlan"
```

Результат — `dist/peridot-wlan/qca_cld3_qca6750.ko`. Локальный `PERIDOT_OUT` приведён как пример сборки: его `vermagic` отличается от штатного, поэтому получившиеся модули нельзя напрямую подставить в штатный образ.

### Qualcomm SPF и LPASS (пример: Poco F6 / Peridot)

```bash
./build-qcom-audio.sh --list
./build-qcom-audio.sh \
  --kernel-src "$KERNEL_SRC" --kernel-out ../out/peridot-nosig/kernel \
  --llvm-bin "$LLVM_BIN" --modules-src ../android_kernel_xiaomi_sm8635-modules \
  --board pineapple --product lineage_peridot --jobs 6 \
  --driver spf --driver lpass --dist "$PWD/dist/peridot-audio"
```

Уберите одну из опций `--driver`, если нужен только другой `.ko`. Профиль собирает `msm_ext_display` для получения его символов и весь аудиопакет, поскольку этот vendor Kbuild ненадёжно собирает отдельные вложенные цели. При выборе двух драйверов в каталоге будут `ipc/audio_pkt_dlkm.ko`, `asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko` и `Module.symvers` аудиопакета. Используйте выходное дерево, соответствующее vendor-исходникам и целевому ядру. Путь из примера указывает на существующую локальную сборку, а не на универсальный релиз.

## 3. Перепаковка vendor_dlkm

```bash
./repack-vendor-dlkm.py --input /path/to/vendor_dlkm.img --list

mkdir -p out
./repack-vendor-dlkm.py \
  --input /path/to/vendor_dlkm.img --output out/vendor_dlkm-repacked.img \
  --replace audio_pkt_dlkm.ko=dist/peridot-audio/ipc/audio_pkt_dlkm.ko \
  --replace lpass_cdc_tx_macro_dlkm.ko=dist/peridot-audio/asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko
```

- Для вложенных модулей укажите точный путь из `--list`. Имя без каталога означает `/lib/modules/NAME.ko`. Цель должна уже существовать, быть обычным несжатым `.ko` и иметь одну жёсткую ссылку. Файлы вроде `modules.load` и `modules.dep` не пересоздаются.
- Скрипт сверяет ELF, метаданные модуля, CRC существующих импортов и экспорты. Для новых версионированных импортов передайте через `--symvers FILE` доверенные таблицы **целевого** ядра и модулей, предоставляющих символы. Скрипт сохраняет права, UID/GID, времена и расширенные атрибуты заменяемого файла, проверяет записанные байты и запускает `e2fsck` до публикации образа. Входной файл остаётся неизменным, существующий выходной файл не перезаписывается.
- **AVB:** образ с AVB-footer отклоняется без явного `--for-resigning`. В этом режиме результат — **только неподписанная файловая система**, а не готовый к загрузке образ раздела. Подготовку размера раздела и подпись выполняйте отдельно штатными инструментами устройства. Даже без footer дескрипторы AVB могут быть в отдельном `vbmeta`: успешная перепаковка не означает, что устройство примет образ.
- Выход всегда raw ext4, даже если вход был sparse ext4. EROFS, сжатые модули, `super.img`, OTA payload и изменение размера ФС не поддерживаются. Если места мало, для **неподписанных** модулей может помочь `--strip-debug "$LLVM_BIN/llvm-strip"`; не применяйте strip после подписи модуля.

## Типовые ошибки

| Симптом | Что проверить |
| --- | --- |
| Нет `Module.symvers`, сгенерированных заголовков или `vmlinux` | Нужен результат полной сборки целевого ядра. `modules_prepare` не создаёт нужные CRC, а для BTF требуется подходящий `vmlinux`. |
| `undefined` от modpost или нет `.ko` | Проверьте `CONFIG_…=m` и путь цели. Для внешних модулей передайте таблицы зависимостей, а если Kbuild не видит зависимости при сборке отдельной цели, используйте `--build-package`. |
| Не совпадает `vermagic` или CRC импортов/экспортов | Пересоберите с целевым ядром и соответствующими модулями, предоставляющими символы. Совпадение `uname -r` не доказывает совместимость ABI/KMI. Не подменяйте `vermagic`. |
| Недостаточно места в ext4 | Возьмите меньшую совместимую сборку либо используйте штатные инструменты сборки Android-образа. Скрипт не увеличивает раздел. |
| Образ прошёл локальные проверки, но модуль не грузится | Проверки ABI не заменяют запуск. Подпись модулей и AVB раздела — разные механизмы; нужны соответствующее ядро, зависимости и штатная схема подписи. Скрипт не проверяет криптографическую подпись. |

Все опции каждого скрипта доступны через `--help`.
