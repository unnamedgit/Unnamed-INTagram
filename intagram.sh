#!/usr/bin/env bash
set -euo pipefail

echo "=== Unnamed INTagram – installazione automatica ==="

# === Percorsi (con spazio, come richiesto) ===
BASE="$HOME/OSINT Tool"
APPDIR="$BASE/intagram"
VENV="$APPDIR/.venv"
PY="$APPDIR/uit.py"
LAUNCH="$APPDIR/intagram.sh"
UPDATE="$APPDIR/update.sh"
BASHRC="$HOME/.bashrc"

mkdir -p "$APPDIR"

# === Assicura python3-venv ===
if ! python3 -m venv --help >/dev/null 2>&1; then
  echo ">> Manca python3-venv. Installo (richiede sudo)…"
  sudo apt-get update -y
  sudo apt-get install -y python3-venv
fi

# === venv ===
if [ ! -d "$VENV" ]; then
  echo ">> Creo virtualenv: $VENV"
  python3 -m venv "$VENV"
fi

# === Attiva venv e pacchetti ===
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel >/dev/null
python -m pip install --no-cache-dir requests browser_cookie3 >/dev/null

# === Script Python: guida chiara, normalizzazione sessionID, tabelle ed export ===
cat > "$PY" <<'PY'
#!/usr/bin/env python3
# Unnamed INTagram (UIT)
# Subcomandi: configure, reconfigure, show-config, from-username, from-id
# Output tabellare + export opzionale. Config sessionID: guida dettagliata e normalizzazione input.

import argparse, json, os, re, sys, time, shutil, textwrap
from pathlib import Path
import requests

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "unnamed-intagram"
CONFIG_FILE = CONFIG_DIR / "config.json"

UA_WEB = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
UA_MOBILE = ("Instagram 289.0.0.0.77 Android (30/11; 420dpi; 1080x1920; Google; Pixel; pixel; qcom; en_US)")
IG_APP_ID = "936619743392459"

class UITError(Exception): pass

# ---------------- Basic I/O ----------------
def load_config():
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

def save_config(cfg: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_FILE)
    try: os.chmod(CONFIG_FILE, 0o600)
    except: pass

def mask(s: str, keep=4):
    if not s: return ""
    if len(s) <= keep*2: return "*"*len(s)
    return s[:keep]+"*"*(len(s)-keep*2)+s[-keep:]

# ---------------- sessionid helpers ----------------
def normalize_sessionid(raw: str) -> str:
    """Accetta input vari (con/ senza 'sessionid=' o ';' o virgolette) e restituisce solo il valore pulito."""
    if not raw: return ""
    s = raw.strip().strip('";\' ')
    # Se l'utente ha incollato 'sessionid=xxxx; Path=/; ...'
    m = re.search(r"sessionid\s*=\s*([^;,\s]+)", s, re.IGNORECASE)
    if m:
        return m.group(1).strip()
    # Altrimenti, prendiamo la prima 'parola' sensata
    s = s.split()[0]
    s = s.split(';')[0]
    return s.strip()

def ensure_sessionid(sessionid: str|None):
    if not sessionid:
        raise UITError("Nessun sessionID configurato.")
    if not re.fullmatch(r"[0-9a-fA-F:%_|\-]{8,}", sessionid):
        print("⚠️  Il sessionID ha un formato inusuale; se hai problemi, riconfiguralo.", file=sys.stderr)
    return sessionid

# ---------------- HTTP ----------------
def mk_session(sessionid: str):
    s = requests.Session()
    s.headers.update({
        "User-Agent": UA_WEB,
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "en-US,en;q=0.9",
        "X-IG-App-ID": IG_APP_ID,
        "Referer": "https://www.instagram.com/",
    })
    s.cookies.set("sessionid", sessionid, domain=".instagram.com")
    s.cookies.set("ig_did", "dummy", domain=".instagram.com")
    return s

def http_json_get(session: requests.Session, url: str, headers: dict|None=None, mobile: bool=False):
    hdrs = dict(session.headers)
    if headers: hdrs.update(headers)
    if mobile:
        hdrs.update({"User-Agent": UA_MOBILE, "Accept": "*/*", "X-IG-App-ID": IG_APP_ID})
    r = session.get(url, headers=hdrs)
    if r.status_code == 429: raise UITError("Rate limit (429). Riprova più tardi.")
    if r.status_code in (401,403): raise UITError("Non autorizzato (401/403). Il sessionID potrebbe essere scaduto.")
    if r.status_code == 404: raise UITError("Non trovato (404).")
    r.raise_for_status()
    try: return r.json()
    except Exception as e: raise UITError(f"Risposta non-JSON: {e}")

# ---------------- IG lookups ----------------
def get_profile_by_username(session, username: str)->dict:
    username = username.strip().lstrip("@")
    url = f"https://www.instagram.com/api/v1/users/web_profile_info/?username={username}"
    data = http_json_get(session, url)
    user = (data.get("data") or {}).get("user") or {}
    if not user: raise UITError("Profilo non trovato o struttura inattesa.")
    return {
        "id": user.get("id"),
        "username": user.get("username"),
        "full_name": user.get("full_name"),
        "is_private": user.get("is_private"),
        "is_verified": user.get("is_verified"),
        "biography": user.get("biography") or "",
        "external_url": user.get("external_url"),
        "followers": (user.get("edge_followed_by") or {}).get("count"),
        "following": (user.get("edge_follow") or {}).get("count"),
        "profile_pic_url": user.get("profile_pic_url"),
    }

def get_user_info_by_id(session, user_id)->dict:
    user_id = str(user_id).strip()
    # mobile
    url_m = f"https://i.instagram.com/api/v1/users/{user_id}/info/"
    last_err = None
    try:
        data = http_json_get(session, url_m, mobile=True)
        u = data.get("user") or {}
        if u:
            return {
                "id": u.get("pk") or u.get("id"),
                "username": u.get("username"),
                "full_name": u.get("full_name"),
                "is_private": u.get("is_private"),
                "is_verified": u.get("is_verified"),
                "biography": u.get("biography") or "",
                "external_url": u.get("external_url"),
                "followers": u.get("follower_count"),
                "following": u.get("following_count"),
                "profile_pic_url": u.get("profile_pic_url") or (u.get("hd_profile_pic_url_info") or {}).get("url"),
            }
    except Exception as e:
        last_err = e
    # web fallback
    url_w = f"https://www.instagram.com/api/v1/users/{user_id}/info/"
    data = http_json_get(session, url_w)
    u = data.get("user") or {}
    if not u: raise UITError(f"Impossibile risolvere ID → username. Ultimo errore: {last_err}")
    return {
        "id": u.get("pk") or u.get("id"),
        "username": u.get("username"),
        "full_name": u.get("full_name"),
        "is_private": u.get("is_private"),
        "is_verified": u.get("is_verified"),
        "biography": u.get("biography") or "",
        "external_url": u.get("external_url"),
        "followers": u.get("follower_count"),
        "following": u.get("following_count"),
        "profile_pic_url": u.get("profile_pic_url"),
    }

# ---------------- Rendering + export ----------------
def term_width(default=100):
    try:
        return shutil.get_terminal_size().columns
    except Exception:
        return default

def wrap_val(v, width):
    if v is None: v = ""
    if not isinstance(v, str): v = str(v)
    return "\n".join(textwrap.wrap(v, width=width, replace_whitespace=False)) or ""

def build_table(title: str, rows: list[tuple[str, str]]):
    tw = term_width()
    key_w = max((len(k) for k,_ in rows), default=0)
    max_w = max(20, tw - key_w - 7)
    bar = "┌" + "─"*(key_w+2) + "┬" + "─"*(max_w+2) + "┐"
    sep = "├" + "─"*(key_w+2) + "┼" + "─"*(max_w+2) + "┤"
    end = "└" + "─"*(key_w+2) + "┴" + "─"*(max_w+2) + "┘"

    lines = [title, bar]
    first = True
    for k,v in rows:
        if not first: lines.append(sep)
        first = False
        val = wrap_val(v, max_w)
        for i, line in enumerate(val.split("\n") if val else [""]):
            kk = f" {k} " if i==0 else " " * (key_w+2)
            vv = " " + (line.ljust(max_w)) + " "
            lines.append("│"+ kk.ljust(key_w+2) +"│"+ vv +"│")
    lines.append(end)
    return "\n".join(lines)

def print_table(title: str, rows: list[tuple[str, str]]):
    print(build_table(title, rows))

def export_table(path: str, title: str, rows: list[tuple[str, str]]):
    txt = build_table(title, rows)
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(txt+"\n")
    return str(p)

# ---------------- Config guide ----------------
GUIDE = """
PRIMA DI INIZIARE — ACCEDI AL TUO PROFILO INSTAGRAM
  1) Apri https://www.instagram.com dal browser che usi di solito.
  2) Esegui l'accesso al profilo con le tue credenziali.
  3) Non usare modalità in incognito. Tieni aperta almeno una scheda di Instagram.

ESTRAZIONE AUTOMATICA (consigliata)
  • Il tool proverà a leggere il cookie 'sessionid' dai browser supportati (Chrome/Chromium/Brave/Edge/Opera/Firefox).
  • Se il keyring del sistema è bloccato, potrebbe chiederti di sbloccarlo. In caso di fallimento, passa alla modalità manuale.

ESTRAZIONE MANUALE (se l'automatica fallisce)
  A) Chrome / Chromium / Brave / Edge / Opera:
     - Vai su instagram.com (già loggato) → premi F12.
     - Scheda "Application" (Applicazione) → "Storage" → "Cookies" → seleziona https://www.instagram.com.
     - Trova la riga con Name = sessionid → copia il Value (solo il valore, senza 'sessionid=' e senza ';').
  B) Firefox:
     - Vai su instagram.com (già loggato) → premi F12.
     - Scheda "Storage" (Archiviazione) → "Cookies" → https://www.instagram.com.
     - Trova "sessionid" → copia il valore.

NOTE
  • Il sessionID può scadere (logout/cambio password/rotazioni). Se ottieni 401/403, riconfiguralo.
  • Se copi accidentalmente 'sessionid=...;' il tool lo pulisce automaticamente.
""".strip()

def print_guide_banner():
    bar = "═"*70
    print(f"\n{bar}\nGUIDA CONFIGURAZIONE SESSIONID\n{bar}\n{GUIDE}\n{bar}\n")

# ---------------- Subcommands ----------------
def cmd_configure(args):
    print_guide_banner()
    cfg = load_config()

    sid = None
    if args.auto:
        print("🔎 Tentativo automatico: lettura cookie 'sessionid' dai browser (Chrome/Chromium/Brave/Edge/Opera/Firefox)…")
        try:
            import browser_cookie3 as bc
            for name in ("chrome","chromium","brave","edge","opera","firefox","load"):
                fn = getattr(bc, name, None)
                if not callable(fn): continue
                try:
                    cj = fn(domain_name=".instagram.com")
                    for c in cj:
                        if c.domain.endswith("instagram.com") and c.name.lower()=="sessionid" and c.value:
                            sid = c.value; break
                except Exception:
                    continue
                if sid: break
        except Exception:
            sid = None
        if sid:
            print("✅ Trovato automaticamente.")
        else:
            print("❌ Non trovato in automatico (forse keyring bloccato o non loggato).")

    if not sid:
        raw = (args.sessionid or input("\nIncolla qui il sessionid (Value): ").strip())
        sid = normalize_sessionid(raw)

    if not sid:
        raise UITError("SessionID vuoto.")

    cfg["sessionid"] = sid
    cfg["updated_at"] = int(time.time())
    save_config(cfg)
    print(f"\n💾 Salvato. SessionID: {mask(sid)}")
    print("Suggerimento: se in futuro ricevi 401/403, esegui 'intagram' → Configurazione sessionID.\n")
    return 0

def cmd_show_config(_):
    cfg = load_config()
    sid = cfg.get("sessionid")
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(cfg.get("updated_at",0))) if cfg.get("updated_at") else "—"
    rows = [
        ("SessionID", mask(sid) if sid else "NON CONFIGURATO"),
        ("Ultimo aggiornamento", when),
        ("Nota", "Se ricevi 401/403, riconfigura (il cookie può scadere)."),
    ]
    print_table(" Stato ", rows)
    return 0

def cmd_from_username(a):
    sid = ensure_sessionid(load_config().get("sessionid"))
    s = mk_session(sid)
    u = get_profile_by_username(s, a.username)
    rows = [
        ("ID", str(u.get("id") or "")),
        ("Username", u.get("username") or ""),
        ("Nome completo", u.get("full_name") or ""),
        ("Privato", str(bool(u.get("is_private")))),
        ("Verificato", str(bool(u.get("is_verified")))),
        ("Follower", str(u.get("followers") or "")),
        ("Following", str(u.get("following") or "")),
        ("Website", u.get("external_url") or ""),
        ("Foto profilo", u.get("profile_pic_url") or ""),
        ("Bio", u.get("biography") or ""),
    ]
    title = " Profilo da USERNAME "
    if a.export:
        out = export_table(a.export, title, rows)
        print(f"📄 Salvato in: {out}")
    else:
        print_table(title, rows)
    return 0

def cmd_from_id(a):
    sid = ensure_sessionid(load_config().get("sessionid"))
    s = mk_session(sid)
    u = get_user_info_by_id(s, a.user_id)
    rows = [
        ("ID", str(u.get("id") or "")),
        ("Username", u.get("username") or ""),
        ("Nome completo", u.get("full_name") or ""),
        ("Privato", str(bool(u.get("is_private")))),
        ("Verificato", str(bool(u.get("is_verified")))),
        ("Follower", str(u.get("followers") or "")),
        ("Following", str(u.get("following") or "")),
        ("Website", u.get("external_url") or ""),
        ("Foto profilo", u.get("profile_pic_url") or ""),
        ("Bio", u.get("biography") or ""),
    ]
    title = " Profilo da ID "
    if a.export:
        out = export_table(a.export, title, rows)
        print(f"📄 Salvato in: {out}")
    else:
        print_table(title, rows)
    return 0

def main():
    p = argparse.ArgumentParser(prog="uit", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    pc = sub.add_parser("configure", help="Guida e configurazione del sessionID (auto/man)")
    pc.add_argument("--auto", action="store_true", help="Prova lettura automatica dai browser")
    pc.add_argument("--sessionid", help="Fornisci manualmente (accetta anche 'sessionid=...;')")
    pc.set_defaults(func=cmd_configure)

    pr = sub.add_parser("reconfigure", help="Alias di configure")
    pr.add_argument("--auto", action="store_true")
    pr.add_argument("--sessionid")
    pr.set_defaults(func=cmd_configure)

    ps = sub.add_parser("show-config", help="Mostra sessionID oscurato e data")
    ps.set_defaults(func=cmd_show_config)

    pu = sub.add_parser("from-username", help="Lookup da username")
    pu.add_argument("username")
    pu.add_argument("--export", help="Percorso TXT per export")
    pu.set_defaults(func=cmd_from_username)

    pi = sub.add_parser("from-id", help="Lookup da ID")
    pi.add_argument("user_id")
    pi.add_argument("--export", help="Percorso TXT per export")
    pi.set_defaults(func=cmd_from_id)

    args = p.parse_args()
    if not args.cmd:
        p.print_help(); return 0
    try:
        return args.func(args)
    except UITError as e:
        print(f"❌ {e}", file=sys.stderr); return 2
    except requests.HTTPError as e:
        print(f"❌ HTTP error: {e}", file=sys.stderr); return 3
    except KeyboardInterrupt:
        print("Interrotto."); return 130

if __name__ == "__main__":
    sys.exit(main())
PY
chmod +x "$PY"

# === Launcher con MENU, schermo pulito e post-menu export TXT ===
cat > "$LAUNCH" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/OSINT Tool/intagram"
VENV="$BASE/.venv"
PY="$BASE/uit.py"

# Determina Desktop (XDG + fallback it)
DESKTOP_DIR="$HOME/Desktop"
if [ -f "$HOME/.config/user-dirs.dirs" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.config/user-dirs.dirs"
  if [ -n "${XDG_DESKTOP_DIR:-}" ]; then
    DESKTOP_DIR="${XDG_DESKTOP_DIR/#\$HOME/$HOME}"
  fi
fi
[ -d "$DESKTOP_DIR" ] || DESKTOP_DIR="$HOME/Scrivania"

# shellcheck disable=SC1091
source "$VENV/bin/activate"

post_menu() {
  echo
  echo "1) Torna al menu principale"
  echo "2) Estrapola le info su un TXT sul Desktop"
  read -rp "Seleziona: " POST
  case "${POST:-}" in
    2)
      local mode="$1"  # username | id
      local val="$2"
      local safe="$(echo "$val" | tr -cd '[:alnum:]_.-')"
      [ -n "$safe" ] || safe="output"
      local ts
      ts="$(date +%Y%m%d_%H%M%S)"
      local out="${DESKTOP_DIR}/${mode}_${safe}_${ts}.txt"
      echo ">> Salvo in: $out"
      if [ "$mode" = "username" ]; then
        "$PY" from-username "$val" --export "$out"
      else
        "$PY" from-id "$val" --export "$out"
      fi
      echo "✔️  File creato."
      read -rp $'\n[Invio per continuare] ' _
      ;;
    *)
      ;;
  esac
}

while true; do
  clear
  echo "==== Unnamed INTagram ===="
  echo "[1] Configurazione sessionID"
  echo "[2] Info da USERNAME"
  echo "[3] Info da ID"
  echo "[4] Stato"
  echo "[5] Aggiorna / Ripara"
  echo "[0] Esci"
  echo
  read -rp "Seleziona: " CH

  case "${CH:-}" in
    1)
      clear
      echo "PRIMA DI INIZIARE — ASSICURATI DI:"
      echo "  • Avere effettuato l'accesso su https://www.instagram.com dal tuo browser (no incognito)."
      echo "  • Tenere aperta almeno una scheda Instagram."
      echo
      echo "Procedo con il tentativo AUTOMATICO? [Y/n]"
      read -r ANS
      ANS="${ANS:-Y}"
      if [[ "$ANS" =~ ^[Yy]$ ]]; then
        "$PY" configure --auto || true
      fi
      echo
      echo "Se l'auto non ha trovato nulla, puoi incollare manualmente il valore del cookie sessionid."
      "$PY" configure || true
      read -rp $'\n[Invio per continuare] ' _
      ;;
    2)
      read -rp "Inserisci USERNAME (senza @): " U
      [ -n "${U:-}" ] || { echo "Username vuoto."; read -rp $'\n[Invio per continuare] ' _; continue; }
      clear
      "$PY" from-username "$U" || true
      post_menu "username" "$U"
      ;;
    3)
      read -rp "Inserisci ID numerico: " ID
      [ -n "${ID:-}" ] || { echo "ID vuoto."; read -rp $'\n[Invio per continuare] ' _; continue; }
      clear
      "$PY" from-id "$ID" || true
      post_menu "id" "$ID"
      ;;
    4)
      clear
      "$PY" show-config || true
      echo
      read -rp $'\n[Invio per continuare] ' _
      ;;
    5)
      clear
      bash "$BASE/update.sh" || true
      echo
      read -rp $'\n[Invio per continuare] ' _
      ;;
    0)
      echo "Ciao!"
      exit 0
      ;;
    *)
      echo "Opzione non valida."
      read -rp $'\n[Invio per continuare] ' _
      ;;
  esac
done
BASH
chmod +x "$LAUNCH"

# === Update/Ripara ===
cat > "$UPDATE" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/OSINT Tool/intagram"
VENV="$BASE/.venv"
PY="$BASE/uit.py"

echo "== Aggiorno/Riparo Unnamed INTagram =="
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel >/dev/null
python -m pip install --no-cache-dir -U requests browser_cookie3 >/dev/null
python -m py_compile "$PY"
echo "✔️  Aggiornamento completato."
BASH
chmod +x "$UPDATE"

# === Alias 'intagram' ===
if ! grep -q 'alias intagram=' "$BASHRC"; then
  echo "alias intagram='bash \"$LAUNCH\"'" >> "$BASHRC"
  echo ">> Alias 'intagram' aggiunto a ~/.bashrc"
fi

deactivate || true

echo
echo "=== Installazione completata ==="
echo "Cartella: $APPDIR"
echo "Usa:  source \"$BASHRC\" && intagram"

