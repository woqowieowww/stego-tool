#!/usr/bin/env bash
set -o pipefail

MAGIC="STEGO"
MAGIC_LEN=5
LEN_BYTES=4
HEADER_LEN=9

error() { echo "ОШИБКА: $*" >&2; }
info() { echo "$*"; }
warn() { echo "ПРЕДУПРЕЖДЕНИЕ: $*" >&2; }

usage() {
    cat <<EOF
Использование:
  $0 --embed -c КОНТЕЙНЕР (-d "ТЕКСТ" | -f ФАЙЛ) [-o ВЫХОДНОЙ]
  $0 --extract -c КОНТЕЙНЕР [-o ВЫХОДНОЙ]          # без -o вывод на экран
  $0 --info -c КОНТЕЙНЕР
  $0 --help
  $0                          # интерактивный режим

Режимы:
  --embed                     встроить данные в контейнер
  --extract                   извлечь данные из контейнера
  --info                      показать информацию о контейнере
  --help                      показать эту справку
EOF
}

for cmd in dd xxd grep od stat; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Не найдена утилита: $cmd"
        exit 1
    fi
done

embed() {
    local container="$1"
    local data="$2"
    local output="$3"

    [[ ! -f "$container" ]] && { error "Контейнер не найден: $container"; return 1; }

    local data_len
    data_len=$(printf "%s" "$data" | wc -c)

    local tmpfile
    tmpfile=$(mktemp)

    {
        printf "%s" "$MAGIC"
        printf "%08x" "$data_len" | xxd -r -p
        printf "%s" "$data"
    } > "$tmpfile"

    cp "$container" "$output"
    cat "$tmpfile" >> "$output"
    rm -f "$tmpfile"

    info "Данные встроены в $output"
    return 0
}

extract() {
    local container="$1"
    local output="$2"
    local to_stdout=0

    [[ -z "$output" ]] && to_stdout=1

    [[ ! -f "$container" ]] && { error "Контейнер не найден: $container"; return 1; }

    local magic_pos
    magic_pos=$(grep -a -b -o "$MAGIC" "$container" | tail -1 | cut -d: -f1)
    if [[ -z "$magic_pos" ]]; then
        error "Магическая строка не найдена в файле"
        return 1
    fi

    local len_hex
    len_hex=$(dd if="$container" bs=1 skip=$((magic_pos + MAGIC_LEN)) count=$LEN_BYTES 2>/dev/null | xxd -p | tr -d '\n')
    if [[ ${#len_hex} -lt $((LEN_BYTES * 2)) ]]; then
        error "Не удалось прочитать длину данных"
        return 1
    fi

    local data_len=$((16#$len_hex))
    local data_start=$((magic_pos + HEADER_LEN))

    if [[ $to_stdout -eq 1 ]]; then
        dd if="$container" bs=1 skip="$data_start" count="$data_len" 2>/dev/null
    else
        dd if="$container" bs=1 skip="$data_start" count="$data_len" of="$output" 2>/dev/null
        info "Данные сохранены в $output"
    fi
    return 0
}

info_container() {
    local file="$1"
    [[ ! -f "$file" ]] && { error "Файл не найден"; return 1; }

    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    local ext="${file##*.}"
    local has_magic="нет"
    grep -a -q "$MAGIC" "$file" && has_magic="да (возможно, есть скрытые данные)"

    echo "Имя файла: $file"
    echo "Размер: $size байт"
    echo "Расширение: $ext"
    echo "Наличие магии STEGO: $has_magic"
}

interactive_menu() {
    while true; do
        echo
        echo "================================================"
        echo "         СТЕГАНОГРАФИЧЕСКИЙ ИНСТРУМЕНТ          "
        echo "================================================"
        echo "1. Встроить сообщение в контейнер"
        echo "2. Извлечь сообщение из контейнера"
        echo "3. Информация о контейнере"
        echo "4. О программе"
        echo "5. Выход"
        read -p "Выберите пункт [1-5]: " choice

        case "$choice" in
            1) interactive_embed ;;
            2) interactive_extract ;;
            3) interactive_info_container ;;
            4) interactive_about ;;
            5) echo "Выход."; exit 0 ;;
            *) error "Неверный пункт" ;;
        esac
    done
}

interactive_embed() {
    local container data data_file output

    read -p "Введите путь к контейнеру: " container
    [[ ! -f "$container" ]] && { error "Файл не найден"; return; }

    echo "Выберите источник данных:"
    echo "1. Ввести текст с клавиатуры"
    echo "2. Указать файл"
    read -p "Ваш выбор [1]: " src_choice
    src_choice=${src_choice:-1}

    if [[ "$src_choice" == "1" ]]; then
        read -p "Введите сообщение: " data
    else
        read -p "Введите путь к файлу: " data_file
        [[ ! -f "$data_file" ]] && { error "Файл не найден"; return; }
        data=$(cat "$data_file")
        warn "Если файл содержит нулевые байты, они могут быть потеряны. Для бинарных данных используйте неинтерактивный режим."
    fi

    output_default="${container%.*}_stego.${container##*.}"
    read -p "Сохранить как [${output_default}]: " output
    output=${output:-$output_default}

    echo "Встраивание..."
    if embed "$container" "$data" "$output"; then
        info "Успешно."
    else
        error "Ошибка при встраивании"
    fi
}

interactive_extract() {
    local container output choice

    read -p "Введите путь к контейнеру: " container
    [[ ! -f "$container" ]] && { error "Файл не найден"; return; }

    echo "Как вывести извлечённые данные?"
    echo "1. Сохранить в файл"
    echo "2. Показать на экране (осторожно: бинарные данные могут испортить терминал)"
    read -p "Ваш выбор [1]: " choice
    choice=${choice:-1}

    if [[ "$choice" == "1" ]]; then
        output_default="extracted_$(date +%s).bin"
        read -p "Сохранить в файл [${output_default}]: " output
        output=${output:-$output_default}
        echo "Извлечение..."
        extract "$container" "$output"
    else
        echo "Извлечение и вывод на экран (непечатные символы будут показаны в виде ^X):"
        extract "$container" "" | cat -v
    fi
}

interactive_info_container() {
    local container
    read -p "Введите путь к контейнеру: " container
    info_container "$container"
}

interactive_about() {
    cat <<EOF

====================== О ПРОГРАММЕ ======================

Этот инструмент предназначен для стеганографии — сокрытия
одних данных внутри других. Он использует самый простой
метод: добавление скрываемых данных в КОНЕЦ файла-контейнера.

Как это работает:
1. Берётся любой файл (картинка, видео, текст, что угодно).
2. В конец этого файла дописывается специальный заголовок:
   - магическая строка "STEGO" (5 байт) — чтобы потом найти данные
   - длина скрытых данных (4 байта, в формате big-endian)
   - сами скрытые данные (в точности как есть)
3. Файл с дописанными данными внешне остаётся работоспособным
   (например, картинка по-прежнему открывается, потому что
   программа просмотра игнорирует лишние данные в конце).

Для чего это нужно?
- Спрятать текст внутри картинки
- Передать файл, замаскировав его под другой файл
- Провести эксперименты в научных целях

КАК ПОЛЬЗОВАТЬСЯ:

ИНТЕРАКТИВНЫЙ РЕЖИМ:
Просто запустите программу без аргументов:
    ./stego_tool.sh
Появится меню, где можно выбрать действие.

РЕЖИМ КОМАНДНОЙ СТРОКИ (для автоматизации):

1. Встроить данные из текста:
   ./stego_tool.sh --embed -c image.jpg -d "Секретное сообщение" -o output.jpg

2. Встроить данные из файла:
   ./stego_tool.sh --embed -c image.jpg -f secret.bin -o output.jpg

3. Извлечь данные в файл:
   ./stego_tool.sh --extract -c output.jpg -o extracted.bin

4. Извлечь данные и вывести на экран:
   ./stego_tool.sh --extract -c output.jpg

5. Посмотреть информацию о контейнере:
   ./stego_tool.sh --info -c output.jpg

ВАЖНЫЕ ЗАМЕЧАНИЯ ДЛЯ ЧАЙНИКОВ:

- Если вы встраиваете текстовое сообщение, оно сохранится как есть.
- Если вы встраиваете бинарный файл (программу, архив, другую картинку),
  то в интерактивном режиме возможна потеря данных (из-за ограничений
  командной оболочки). Для бинарных данных ВСЕГДА используйте
  неинтерактивный режим с ключом -f.

- При извлечении на экран бинарные данные могут отображаться как
  бессмысленные символы — это нормально. Чтобы посмотреть их
  шестнадцатеричный дамп, можно потом воспользоваться командой
  xxd extracted.bin.

- Метод append не изменяет исходное содержимое контейнера,
  поэтому размер выходного файла будет больше исходного.

- Если в контейнере уже есть скрытые данные (магия STEGO),
  программа найдёт последние. Повторное встраивание добавит
  ещё один блок в конец — старые данные останутся.

- Для проверки, есть ли в файле скрытые данные, используйте
  пункт меню "Информация о контейнере".

Примеры 

  Спрятать текст "Привет, мир!" в картинку photo.jpg:
    ./stego_tool.sh --embed -c photo.jpg -d "Привет, мир!" -o photo_secret.jpg

  Извлечь и посмотреть на экране:
    ./stego_tool.sh --extract -c photo_secret.jpg

  Спрятать файл archive.zip в video.mp4:
    ./stego_tool.sh --embed -c video.mp4 -f archive.zip -o video_with_zip.mp4

  Извлечь архив обратно:
    ./stego_tool.sh --extract -c video_with_zip.mp4 -o extracted.zip

ОГРАНИЧЕНИЯ:
- Максимальный размер скрытых данных — около 4 гигабайт (из-за 4-байтовой длины).
- При извлечении на экран бинарные данные могут «сломать» терминал
  (появятся странные символы и звуки). Если такое случилось, закройте
  вкладку терминала или наберите команду reset (слепым набором).
  Поэтому для бинарных данных лучше сразу сохранять в файл.
Авторы: Позевалкин В.В., Хабиров А.А., Руднев Н.А.
EOF
}

if [[ $# -eq 0 ]]; then
    interactive_menu
    exit 0
fi

MODE=""
CONTAINER=""
DATA=""
FILE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --embed) MODE="embed" ;;
        --extract) MODE="extract" ;;
        --info) MODE="info" ;;
        --help) usage; exit 0 ;;
        -c) CONTAINER="$2"; shift ;;
        -d) DATA="$2"; shift ;;
        -f) FILE="$2"; shift ;;
        -o) OUTPUT="$2"; shift ;;
        *) error "Неизвестный аргумент: $1"; usage; exit 1 ;;
    esac
    shift
done

if [[ -z "$MODE" ]]; then
    error "Не указан режим (--embed, --extract, --info)"
    usage
    exit 1
fi

if [[ "$MODE" == "embed" ]]; then
    [[ -z "$CONTAINER" ]] && { error "Не указан контейнер (-c)"; exit 1; }

    if [[ -n "$FILE" ]]; then
        [[ ! -f "$FILE" ]] && { error "Файл с данными не найден: $FILE"; exit 1; }
        DATA=$(cat "$FILE")
    elif [[ -z "$DATA" ]]; then
        error "Не указаны данные (используйте -d или -f)"
        exit 1
    fi

    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="${CONTAINER%.*}_stego.${CONTAINER##*.}"
    fi

    embed "$CONTAINER" "$DATA" "$OUTPUT"
fi

if [[ "$MODE" == "extract" ]]; then
    [[ -z "$CONTAINER" ]] && { error "Не указан контейнер (-c)"; exit 1; }
    extract "$CONTAINER" "$OUTPUT"
fi

if [[ "$MODE" == "info" ]]; then
    [[ -z "$CONTAINER" ]] && { error "Не указан контейнер (-c)"; exit 1; }
    info_container "$CONTAINER"
fi
