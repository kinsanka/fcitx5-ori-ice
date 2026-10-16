#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fedora 44 + niri: Fcitx5 / Rime Ice / Ori. Run as your desktop user.
set -Eeuo pipefail
umask 077

ICE_REV=da1fbe602e38f26db846fa10120ee64c2b0324c0
ICE_SHA=6e6c0e8c00b969690dbc8b394b0a8f8cb0ed3ad348297ad631de1790c693eebb
ORI_REV=d2cf5df38f11e4e14dcf9436af5b9f8fa0087c55
ORI_SHA=141000fe496b4e0996c5e850f72f917e1bdc2bd90cd71e3fe04c922bef8c5e8d
THEME=dark
SCHEMA=rime_ice
ACTION=install
RESTORE_ID=
WORK=
BACKUP=
ARMED=0
WAS_RUNNING=0
STOPPED=0
CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}
DATA_ROOT=${XDG_DATA_HOME:-"$HOME/.local/share"}
STATE_ROOT=${XDG_STATE_HOME:-"$HOME/.local/state"}/fcitx5-ori-ice
NIRI_CONFIG=${NIRI_CONFIG:-"$CONFIG_ROOT/niri/config.kdl"}
export CONFIG_ROOT DATA_ROOT STATE_ROOT NIRI_CONFIG ICE_REV ORI_REV

log() { printf '\n[Ori Ice] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Fedora 44 + niri 输入法组合包
用法：bash install.sh [选项]
  --theme dark|light|auto    Ori 深色（默认）、浅色、跟随系统
  --schema SCHEMA           rime_ice（默认全拼）、double_pinyin_flypy（小鹤）等
  --restore latest|备份名    恢复配置；同时备份恢复前的状态
  --check                   只检查依赖、配置和编译产物
  --help                    显示帮助
不要使用 sudo bash；脚本只在安装 Fedora 软件包时使用 sudo。
HELP
}

# A single downloadable file; the Python portion is also exercised by tests.
configure() {
    python3 - "$@" <<'PY_CONFIG'
import configparser
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".ori-ice-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def paths(legacy=False):
    config = Path(os.environ["CONFIG_ROOT"])
    data = Path(os.environ["DATA_ROOT"])
    targets = [
        (config if legacy else data) / "fcitx5/rime",
        config / "fcitx5/profile",
        config / "fcitx5/conf/classicui.conf",
        data / "fcitx5/themes/OriDark",
        data / "fcitx5/themes/OriLight",
        Path(os.environ["NIRI_CONFIG"]),
        config / "niri/fcitx5-ori-ice.kdl",
        config / "environment.d/90-fcitx5-ori-ice.conf",
        config / "fcitx5-ori-ice/session.sh",
        Path(os.environ["STATE_ROOT"]) / "installed.json",
    ]
    if not legacy:
        targets.append(config / "fcitx5/rime")
    return targets


def preflight(require_niri=True):
    for path in paths():
        if not path.is_absolute():
            raise ValueError(f"路径必须是绝对路径：{path}")
        for parent in [path, *path.parents]:
            if parent.is_symlink():
                raise ValueError(f"暂不修改符号链接，请先改用实际配置路径：{parent}")
    niri = Path(os.environ["NIRI_CONFIG"])
    if require_niri and not niri.is_file():
        raise ValueError(f"找不到 niri 配置：{niri}；可用 NIRI_CONFIG 指定实际文件")


def snapshot(backup):
    backup = Path(backup)
    if (backup / "manifest.json").exists():
        raise ValueError("备份目录已使用")
    entries = []
    for index, path in enumerate(paths()):
        exists = path.exists()
        entry = {"path": str(path), "exists": exists, "slot": str(index)}
        if exists:
            target = backup / str(index)
            if path.is_dir():
                shutil.copytree(path, target, symlinks=True)
            else:
                shutil.copy2(path, target)
        entries.append(entry)
    # The manifest is the commit marker: incomplete backups cannot be restored.
    write(backup / "manifest.json", json.dumps(entries, ensure_ascii=False))


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def restore(backup):
    backup = Path(backup)
    entries = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    expected = [[str(path) for path in paths(legacy=old)] for old in [False, True]]
    if [entry["path"] for entry in entries] not in expected:
        raise ValueError("备份的配置路径与当前环境不一致，拒绝恢复")
    for index, entry in enumerate(entries):
        source = backup / str(index)
        if entry["slot"] != str(index) or (entry["exists"] and not source.exists()):
            raise ValueError("备份不完整，拒绝恢复")
    for index, entry in enumerate(entries):
        path = Path(entry["path"])
        remove(path)
        if entry["exists"]:
            path.parent.mkdir(parents=True, exist_ok=True)
            source = backup / str(index)
            if source.is_dir():
                shutil.copytree(source, path, symlinks=True)
            else:
                shutil.copy2(source, path)


def profile_text(text):
    parser = configparser.ConfigParser(interpolation=None, delimiters=("=",))
    parser.optionxform = str
    parser.read_string(text)
    groups = [s for s in parser.sections() if re.fullmatch(r"Groups/\d+", s)]
    group = next((s for s in groups if parser[s].get("Name") == "Ori Ice"), None)
    if group is None:
        index = max([int(s.split("/")[1]) for s in groups], default=-1) + 1
        group = f"Groups/{index}"
        parser.add_section(group)
    layout = parser[group].get("Default Layout", "")
    if not layout:
        layout = next((parser[s].get("Default Layout") for s in groups
                       if parser[s].get("Default Layout")), "us")
    parser[group].update({"Name": "Ori Ice", "Default Layout": layout,
                          "DefaultIM": "rime"})
    for section in list(parser.sections()):
        if section.startswith(group + "/Items/"):
            parser.remove_section(section)
    for index, name in enumerate(["keyboard-" + layout, "rime"]):
        section = f"{group}/Items/{index}"
        parser.add_section(section)
        parser[section].update({"Name": name, "Layout": ""})
    if not parser.has_section("GroupOrder"):
        parser.add_section("GroupOrder")
    order = [value for key, value in sorted(parser["GroupOrder"].items(),
             key=lambda pair: int(pair[0]) if pair[0].isdigit() else 9999)
             if value != "Ori Ice"]
    for section in groups:
        name = parser[section].get("Name")
        if name and name != "Ori Ice" and name not in order:
            order.append(name)
    parser["GroupOrder"].clear()
    parser["GroupOrder"].update({str(i): name for i, name in
                                 enumerate(["Ori Ice", *order])})
    output = io.StringIO()
    parser.write(output, space_around_delimiters=False)
    return output.getvalue()


def root_ini(text, values):
    lines = text.splitlines()
    end = next((i for i, line in enumerate(lines) if line.lstrip().startswith("[")),
               len(lines))
    result = []
    pending = dict(values)
    for line in lines[:end]:
        key = line.split("=", 1)[0].strip() if "=" in line else None
        if key in values:
            if key in pending:
                result.append(f"{key}={pending.pop(key)}")
        else:
            result.append(line)
    result += [f"{key}={value}" for key, value in pending.items()]
    return "\n".join(result + lines[end:]) + "\n"


def read(path):
    return path.read_text(encoding="utf-8") if path.exists() else ""


def migrate_legacy_rime(source, target):
    """Recover missing old-install files; native data always wins conflicts."""
    if not source.exists():
        return

    def copy_missing(src, dst):
        if src.is_symlink() or dst.is_symlink():
            raise ValueError(f"不迁移符号链接：{src} -> {dst}")
        if src.is_dir():
            # A user database/sync snapshot must never be merged file by file.
            if src.name.endswith(".userdb") or src.name == "sync":
                if not dst.exists():
                    shutil.copytree(src, dst)
                return
            if dst.exists() and not dst.is_dir():
                return
            dst.mkdir(parents=True, exist_ok=True)
            for child in src.iterdir():
                copy_missing(child, dst / child.name)
        elif not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    for child in source.iterdir():
        if child.name not in {"build", "installation.yaml", "user.yaml"}:
            copy_missing(child, target / child.name)


def apply(work, theme, schema):
    import yaml
    preflight()
    config = Path(os.environ["CONFIG_ROOT"])
    data = Path(os.environ["DATA_ROOT"])
    state = Path(os.environ["STATE_ROOT"])
    work = Path(work)
    rime = data / "fcitx5/rime"
    migrate_legacy_rime(config / "fcitx5/rime", rime)
    rime.mkdir(parents=True, exist_ok=True)
    # Preserve user dictionaries, *.custom.yaml, sync data and custom phrases.
    # Upstream-owned schemas, dictionaries and Lua code are replaced on update.
    for source in (work / "ice").rglob("*"):
        relative = source.relative_to(work / "ice")
        if any(part.startswith(".") for part in relative.parts):
            continue
        if relative.parts[0] in {"build", "others", "LICENSE", "README.md", "AGENTS.md"}:
            continue
        target = rime / relative
        if source.is_file():
            if target.exists() and (source.name.endswith(".custom.yaml") or
                                    source.name == "custom_phrase.txt"):
                continue
            if target.is_symlink():
                raise ValueError(f"不覆盖用户目录中的符号链接：{target}")
            # Check parent links as well before copy2 follows them.
            if any(parent.is_symlink() for parent in target.parents):
                raise ValueError(f"不写入符号链接目录：{target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    custom_path = rime / "default.custom.yaml"
    custom = yaml.safe_load(read(custom_path)) or {}
    if not isinstance(custom, dict) or not isinstance(custom.get("patch", {}), dict):
        raise ValueError("default.custom.yaml 的 patch 必须是映射")
    custom.setdefault("patch", {})["schema_list"] = [{"schema": schema}]
    write(custom_path, yaml.safe_dump(custom, allow_unicode=True, sort_keys=False))
    user_path = rime / "user.yaml"
    user = yaml.safe_load(read(user_path)) or {}
    if not isinstance(user, dict) or not isinstance(user.get("var", {}), dict):
        raise ValueError("user.yaml 的 var 必须是映射")
    user.setdefault("var", {})["previously_selected_schema"] = schema
    write(user_path, yaml.safe_dump(user, allow_unicode=True, sort_keys=False))
    for name in ["OriDark", "OriLight"]:
        target = data / "fcitx5/themes" / name
        remove(target)
        shutil.copytree(work / "ori" / name, target)
    profile = config / "fcitx5/profile"
    write(profile, profile_text(read(profile)))
    classic = config / "fcitx5/conf/classicui.conf"
    write(classic, root_ini(read(classic), {
        "Theme": "OriLight" if theme in {"light", "auto"} else "OriDark",
        "DarkTheme": "OriDark", "UseDarkTheme": "True" if theme == "auto" else "False",
        "UseAccentColor": "False",
    }))
    # Run at every niri login so systemd/D-Bus launchers see the same IM variables.
    # GTK_IM_MODULE stays unset for native Wayland; legacy apps opt in individually.
    session = config / "fcitx5-ori-ice/session.sh"
    write(session, '''#!/bin/sh
export XMODIFIERS=@im=fcitx
export QT_IM_MODULE=fcitx
export QT_IM_MODULES='wayland;fcitx'
unset GTK_IM_MODULE
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user unset-environment GTK_IM_MODULE || :
    systemctl --user import-environment XMODIFIERS QT_IM_MODULE QT_IM_MODULES || :
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment XMODIFIERS QT_IM_MODULE QT_IM_MODULES GTK_IM_MODULE= || :
fi
if ! pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1; then
    exec fcitx5
fi
''')
    envfile = config / "environment.d/90-fcitx5-ori-ice.conf"
    write(envfile, "# Managed by fcitx5-ori-ice\nXMODIFIERS=@im=fcitx\n"
          "QT_IM_MODULE=fcitx\nQT_IM_MODULES=wayland;fcitx\n")
    fragment = config / "niri/fcitx5-ori-ice.kdl"
    quote = lambda value: json.dumps(str(value), ensure_ascii=False)
    write(fragment, '// Managed by fcitx5-ori-ice\nenvironment {\n'
          '    XMODIFIERS "@im=fcitx"\n    QT_IM_MODULE "fcitx"\n'
          '    QT_IM_MODULES "wayland;fcitx"\n    GTK_IM_MODULE null\n}\n'
          f'spawn-at-startup "sh" {quote(session)}\n')
    niri = Path(os.environ["NIRI_CONFIG"])
    text = read(niri)
    begin = "// BEGIN fcitx5-ori-ice"
    end = "// END fcitx5-ori-ice"
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise ValueError("niri 配置中的组合包标记不完整，请先修复")
    text = re.sub(r"(?m)^// BEGIN fcitx5-ori-ice\n.*?^// END fcitx5-ori-ice\n?",
                  "", text, flags=re.S)
    write(niri, text.rstrip() + f"\n\n{begin}\ninclude {quote(fragment)}\n{end}\n")
    write(state / "installed.json", json.dumps({"theme": theme, "schema": schema,
          "ice_commit": os.environ["ICE_REV"], "ori_commit": os.environ["ORI_REV"]},
          ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    action, *args = sys.argv[1:]
    if action == "preflight":
        preflight(not args or args[0] != "restore")
    elif action == "snapshot":
        snapshot(*args)
    elif action == "restore":
        preflight(require_niri=False)
        restore(*args)
    elif action == "apply":
        apply(*args)
    else:
        raise ValueError("未知操作")
PY_CONFIG
}

running() { pgrep -u "$(id -u)" -x fcitx5 >/dev/null 2>&1; }

stop_fcitx() {
    if running; then
        WAS_RUNNING=1
        fcitx5-remote -e || die '无法正常退出 Fcitx5，请退出后重试'
        STOPPED=1
        for ((i=0; i<50; i++)); do
            if ! running; then return; fi
            sleep 0.1
        done
        die 'Fcitx5 尚未退出；未修改用户配置'
    fi
}

cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if (( code != 0 && ARMED == 1 )); then
        log "安装未完成，正在恢复配置：$BACKUP"
        if ! configure restore "$BACKUP"; then
            printf '[错误] 自动恢复失败，备份保留在 %s\n' "$BACKUP" >&2
        fi
    fi
    if (( STOPPED == 1 && WAS_RUNNING == 1 )) && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        fcitx5 -d 9>&- >/dev/null 2>&1 || true
    fi
    if [[ -n $WORK && -d $WORK ]]; then rm -rf -- "$WORK"; fi
    exit "$code"
}

download() {
    local url=$1 target=$2 hash=$3
    curl --fail --location --show-error --retry 3 --connect-timeout 20 \
        --max-time 300 --proto '=https' --tlsv1.2 "$url" -o "$target"
    printf '%s  %s\n' "$hash" "$target" | sha256sum --check --status \
        || die "下载校验失败：$url"
}

new_backup() {
    mkdir -p "$STATE_ROOT/backups"
    BACKUP=$(mktemp -d "$STATE_ROOT/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    configure snapshot "$BACKUP"
}

main() {
    while (( $# )); do
        case $1 in
            --help|-h) usage; return ;;
            --theme) [[ $# -ge 2 ]] || die '--theme 缺少参数'; THEME=$2; shift 2 ;;
            --schema) [[ $# -ge 2 ]] || die '--schema 缺少参数'; SCHEMA=$2; shift 2 ;;
            --restore) [[ $# -ge 2 ]] || die '--restore 缺少参数'; ACTION=restore; RESTORE_ID=$2; shift 2 ;;
            --check) ACTION=check; shift ;;
            *) die "未知参数：$1（使用 --help 查看帮助）" ;;
        esac
    done
    case $THEME in dark|light|auto) ;; *) die '主题仅支持 dark、light、auto' ;; esac
    case $SCHEMA in rime_ice|double_pinyin|double_pinyin_abc|double_pinyin_mspy|double_pinyin_sogou|double_pinyin_flypy|double_pinyin_ziguang|double_pinyin_jiajia) ;; *) die '不支持的输入方案，参见 README' ;; esac
    [[ $(uname -s) == Linux ]] || die '请在 Fedora 44 的终端中运行'
    (( EUID != 0 )) || die '请使用普通桌面用户运行，不要使用 sudo bash'
    [[ -r /etc/os-release ]] || die '找不到 /etc/os-release'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == fedora && ${VERSION_ID:-} == 44 ]] || die '当前仅支持 Fedora 44'
    [[ ! -e /run/ostree-booted ]] || die '当前脚本适用于 DNF 版 Fedora，不支持 Atomic/rpm-ostree'
    for cmd in python3 niri pgrep; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done
    configure preflight "$ACTION"
    if [[ $ACTION != restore ]]; then niri validate -c "$NIRI_CONFIG"; fi

    if [[ $ACTION == check ]]; then
        rpm -q fcitx5 fcitx5-rime librime-lua librime-tools fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6
        [[ -f $STATE_ROOT/installed.json ]] || die '尚未安装此组合包'
        cat "$STATE_ROOT/installed.json"
        local selected
        selected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$STATE_ROOT/installed.json")
        [[ -s $DATA_ROOT/fcitx5/rime/build/$selected.schema.yaml &&
           -s $DATA_ROOT/fcitx5/rime/build/rime_ice.table.bin &&
           -f $DATA_ROOT/fcitx5/themes/OriDark/theme.conf &&
           -f $DATA_ROOT/fcitx5/themes/OriLight/theme.conf ]] || die '编译产物或皮肤缺失，请重新安装'
        if running; then log 'Fcitx5 正在运行'; else log 'Fcitx5 未运行；请注销后重新登录 niri'; fi
        log '文件与依赖检查通过；实际打字请在应用中验证'
        return
    fi

    command -v flock >/dev/null || die '缺少 flock（util-linux）'
    mkdir -p "$STATE_ROOT"
    exec 9>"$STATE_ROOT/install.lock"
    flock -n 9 || die '已有一个组合包安装/恢复任务正在运行'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $ACTION == restore ]]; then
        local restore_path
        if [[ $RESTORE_ID == latest ]]; then
            restore_path=$(python3 -c 'from pathlib import Path; import sys; items=list(Path(sys.argv[1]).glob("*/manifest.json")); print(max(items, key=lambda p: p.stat().st_mtime_ns).parent if items else "")' "$STATE_ROOT/backups")
        else
            [[ $RESTORE_ID =~ ^[0-9]{8}-[0-9]{6}-[A-Za-z0-9]+$ ]] || die '无效的备份名'
            restore_path=$STATE_ROOT/backups/$RESTORE_ID
        fi
        [[ -n $restore_path && -f $restore_path/manifest.json ]] || die '找不到完整备份'
        command -v fcitx5-remote >/dev/null || die '缺少 fcitx5-remote'
        stop_fcitx
        new_backup
        ARMED=1
        configure restore "$restore_path"
        niri validate -c "$NIRI_CONFIG"
        ARMED=0
        log "已恢复：$restore_path；恢复前的状态备份在：$BACKUP"
        log '请注销并重新登录；通过 DNF 安装的软件包仍然保留'
        return
    fi

    log '安装 Fedora 官方依赖（sudo 仅用于 DNF）'
    sudo dnf install -y fcitx5 fcitx5-rime fcitx5-configtool \
        fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 \
        librime-lua librime-tools python3-pyyaml curl tar gzip
    python3 -c 'import yaml'
    command -v rime_deployer >/dev/null || die '缺少 rime_deployer'
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/fcitx5-ori-ice.XXXXXXXX")
    mkdir "$WORK/ice" "$WORK/ori"
    log '下载并校验雾凇拼音与 Ori 皮肤'
    download "https://codeload.github.com/iDvel/rime-ice/tar.gz/$ICE_REV" "$WORK/ice.tar.gz" "$ICE_SHA"
    download "https://codeload.github.com/Reverier-Xu/Ori-fcitx5/tar.gz/$ORI_REV" "$WORK/ori.tar.gz" "$ORI_SHA"
    tar -xzf "$WORK/ice.tar.gz" -C "$WORK/ice" --strip-components=1 --no-same-owner
    tar -xzf "$WORK/ori.tar.gz" -C "$WORK/ori" --strip-components=1 --no-same-owner
    [[ -f $WORK/ice/$SCHEMA.schema.yaml && -f $WORK/ori/OriDark/theme.conf &&
       -f $WORK/ori/OriLight/theme.conf ]] || die '上游资源不完整'
    stop_fcitx
    new_backup
    log "配置备份完成：$BACKUP"
    ARMED=1
    configure apply "$WORK" "$THEME" "$SCHEMA"
    niri validate -c "$NIRI_CONFIG"
    log '编译雾凇词库，首次部署可能需要几分钟'
    rime_deployer --build "$DATA_ROOT/fcitx5/rime" /usr/share/rime-data \
        "$DATA_ROOT/fcitx5/rime/build" >"$BACKUP/deploy.log" 2>&1 \
        || { tail -n 40 "$BACKUP/deploy.log" >&2; die "部署失败，日志：$BACKUP/deploy.log"; }
    [[ -s $DATA_ROOT/fcitx5/rime/build/$SCHEMA.schema.yaml &&
       -s $DATA_ROOT/fcitx5/rime/build/rime_ice.table.bin ]] || die '雾凇编译产物缺失'
    ARMED=0
    printf '%s\n' "$(basename "$BACKUP")" >"$STATE_ROOT/latest-backup"
    log '安装完成。请注销并重新登录 niri，然后用 Ctrl+Space 切换输入法。'
    printf '主题：%s；方案：%s\n备份：%s\n' "$THEME" "$SCHEMA" "$BACKUP"
    printf '检查：bash install.sh --check\n恢复：bash install.sh --restore %s\n' "$(basename "$BACKUP")"
    printf 'Chromium/Electron 若不能输入中文，请参阅仓库 README 的应用兼容说明。\n'
    if pgrep -u "$(id -u)" -x ibus-daemon >/dev/null 2>&1; then
        printf '检测到 IBus 正在运行；若重新登录后仍有冲突，请检查原有 IBus 自启动项。\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
