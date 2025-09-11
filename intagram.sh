#!/usr/bin/env bash
set -euo pipefail

echo "=== Unnamed INTagram – installazione (download profilo intero) ==="

BASE="$HOME/OSINT Tool"
APPDIR="$BASE/intagram"
VENV="$APPDIR/.venv"
PY="$APPDIR/uit.py"
LAUNCH="$APPDIR/intagram.sh"
UPDATE="$APPDIR/update.sh"
BASHRC="$HOME/.bashrc"

mkdir -p "$APPDIR"

# Assicura python3-venv
if ! python3 -m venv --help >/dev/null 2>&1; then
  echo ">> Manca python3-venv. Installo (richiede sudo)…"
  sudo apt-get update -y
  sudo apt-get install -y python3-venv
fi

# venv
if [ ! -d "$VENV" ]; then
  echo ">> Creo virtualenv: $VENV"
  python3 -m venv "$VENV"
fi

# Attiva venv e pacchetti
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install -U pip wheel >/dev/null
python -m pip install --no-cache-dir requests browser_cookie3 >/dev/null

# === uit.py con: lookup, extra sensibili, export unico TXT, e DOWNLOAD PROFILO INTERO ===
cat > "$PY" <<'PY'
#!/usr/bin/env python3
import argparse, json, os, re, sys, time, shutil, textwrap, datetime
from pathlib import Path
import requests

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "unnamed-intagram"
CONFIG_FILE = CONFIG_DIR / "config.json"
UA_WEB = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
UA_MOBILE = ("Instagram 289.0.0.0.77 Android (30/11; 420dpi; 1080x1920; Google; Pixel; pixel; qcom; en_US)")
IG_APP_ID = "936619743392459"

class UITError(Exception): pass

# ---------------- Basic I/O ----------------
def load_config():
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r", encoding="utf-8") as f: return json.load(f)
    return {}
def save_config(cfg: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f: json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_FILE)
    try: os.chmod(CONFIG_FILE, 0o600)
    except: pass
def mask(s: str, keep=4):
    if not s: return ""
    if len(s) <= keep*2: return "*"*len(s)
    return s[:keep]+"*"*(len(s)-keep*2)+s[-keep:]

# ---------------- sessionid helpers ----------------
def normalize_sessionid(raw: str) -> str:
    if not raw: return ""
    s = raw.strip().strip('";\' ')
    m = re.search(r"sessionid\s*=\s*([^;,\s]+)", s, re.IGNORECASE)
    if m: return m.group(1).strip()
    s = s.split()[0]; s = s.split(';')[0]
    return s.strip()
def ensure_sessionid(sessionid: str|None):
    if not sessionid: raise UITError("Nessun sessionID configurato.")
    if not re.fullmatch(r"[0-9a-fA-F:%_|\-]{8,}", sessionid):
        print("⚠️  Il sessionID ha un formato inusuale; se hai problemi, riconfiguralo.", file=sys.stderr)
    return sessionid

# ---------------- HTTP ----------------
def mk_session(sessionid: str):
    s = requests.Session()
    s.headers.update({
        "User-Agent": UA_MOBILE,  # per feed mobile
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "X-IG-App-ID": IG_APP_ID,
        "Referer": "https://www.instagram.com/",
    })
    s.cookies.set("sessionid", sessionid, domain=".instagram.com")
    s.cookies.set("ig_did", "dummy", domain=".instagram.com")
    return s
def http_json_get(session: requests.Session, url: str, headers: dict|None=None):
    hdrs = dict(session.headers)
    if headers: hdrs.update(headers)
    r = session.get(url, headers=hdrs)
    if r.status_code == 429: raise UITError("Rate limit (429). Riprova più tardi.")
    if r.status_code in (401,403): raise UITError("Non autorizzato (401/403). Il sessionID potrebbe essere scaduto.")
    if r.status_code == 404: raise UITError("Non trovato (404).")
    r.raise_for_status()
    try: return r.json()
    except Exception as e: raise UITError(f"Risposta non-JSON: {e}")

# ---------------- Lookup base ----------------
def get_profile_by_username(session, username: str)->dict:
    username = username.strip().lstrip("@")
    # Per info anagrafiche usiamo la rotta web_profile_info (risposta strutturata)
    url = f"https://www.instagram.com/api/v1/users/web_profile_info/?username={username}"
    data = http_json_get(session, url, headers={"User-Agent": UA_WEB})
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
        "public_email": user.get("public_email"),
        "business_email": user.get("business_email"),
        "public_phone_number": user.get("public_phone_number"),
        "business_phone_number": user.get("business_phone_number"),
        "business_contact_method": user.get("business_contact_method"),
        "category": user.get("category"),
        "business_category_name": user.get("business_category_name"),
        "is_whatsapp_linked": user.get("is_whatsapp_linked"),
    }
def get_user_info_by_id(session, user_id)->dict:
    user_id = str(user_id).strip()
    # rotta mobile: più adatta a feed e media info
    url_m = f"https://i.instagram.com/api/v1/users/{user_id}/info/"
    data = http_json_get(session, url_m)
    u = data.get("user") or {}
    if not u:
        # fallback web
        url_w = f"https://www.instagram.com/api/v1/users/{user_id}/info/"
        data = http_json_get(session, url_w, headers={"User-Agent": UA_WEB})
        u = data.get("user") or {}
    if not u: raise UITError("Utente non trovato.")
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
        "public_email": u.get("public_email") or u.get("public_email_contact"),
        "business_email": u.get("business_email"),
        "public_phone_number": u.get("public_phone_number"),
        "business_phone_number": u.get("business_phone_number"),
        "business_contact_method": u.get("business_contact_method"),
        "category": u.get("category"),
        "business_category_name": u.get("business_category_name"),
        "is_whatsapp_linked": u.get("is_whatsapp_linked"),
    }

# ---------------- Rendering + export TXT ----------------
def term_width(default=100):
    try: return shutil.get_terminal_size().columns
    except Exception: return default
def wrap_val(v, w):
    if v is None: v = ""
    if not isinstance(v, str): v = str(v)
    return "\n".join(textwrap.wrap(v, width=w, replace_whitespace=False)) or ""
def build_table(title, rows):
    tw = term_width()
    key_w = max((len(k) for k,_ in rows), default=0)
    max_w = max(20, tw - key_w - 7)
    bar = "┌" + "─"*(key_w+2) + "┬" + "─"*(max_w+2) + "┐"
    sep = "├" + "─"*(key_w+2) + "┼" + "─"*(max_w+2) + "┤"
    end = "└" + "─"*(key_w+2) + "┴" + "─"*(max_w+2) + "┘"
    out = [title, bar]; first = True
    for k,v in rows:
        if not first: out.append(sep)
        first = False
        val = wrap_val(v, max_w)
        for i, line in enumerate(val.split("\n") if val else [""]):
            kk = f" {k} " if i==0 else " " * (key_w+2)
            vv = " " + (line.ljust(max_w)) + " "
            out.append("│"+ kk.ljust(key_w+2) +"│"+ vv +"│")
    out.append(end)
    return "\n".join(out)
def print_table(title, rows): print(build_table(title, rows))
def export_table(path, title, rows, mode="a"):
    txt = build_table(title, rows) + "\n"
    p = Path(path); p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, mode, encoding="utf-8") as f: f.write(txt)
    return str(p)

def collect_sensitive_fields(user: dict):
    keys = [
        ("Email pubblica", "public_email"),
        ("Email business", "business_email"),
        ("Telefono pubblico", "public_phone_number"),
        ("Telefono business", "business_phone_number"),
        ("Metodo contatto business", "business_contact_method"),
        ("Categoria", "category"),
        ("Categoria business", "business_category_name"),
        ("WhatsApp collegato", "is_whatsapp_linked"),
    ]
    out = []
    for label, k in keys:
        val = user.get(k)
        if isinstance(val, dict): v = val.get("number") or val.get("display_number") or ""
        else: v = val or ""
        if str(v).strip(): out.append((label, str(v)))
    return out

# ---------------- Feed & Download (full profile) ----------------
def best_image_url(item):
    candidates = []
    if "image_versions2" in item:
        candidates = item["image_versions2"].get("candidates", [])
    elif "thumbnail_resources" in item:
        candidates = item["thumbnail_resources"]
    if candidates:
        # prendi la più grande
        cand = sorted(candidates, key=lambda c: c.get("width", 0), reverse=True)[0]
        return cand.get("url")
    return None
def best_video_url(item):
    versions = item.get("video_versions") or []
    if versions:
        return sorted(versions, key=lambda v: v.get("width", 0), reverse=True)[0].get("url")
    return None

def iter_user_feed(session, user_id):
    """
    Itera TUTTI i post del profilo usando la rotta mobile:
    /api/v1/feed/user/{user_id}/?max_id=<cursor>
    """
    max_id = None
    while True:
        url = f"https://i.instagram.com/api/v1/feed/user/{user_id}/"
        if max_id: url += f"?max_id={max_id}"
        data = http_json_get(session, url)
        items = data.get("items") or []
        for it in items: yield it
        if not data.get("more_available"):
            break
        max_id = data.get("next_max_id") or data.get("next_min_id") or data.get("next_max_id")
        if not max_id: break
        time.sleep(0.6)  # piccola pausa per evitare rate limit

def download_url(session, url, dest_path):
    r = session.get(url, stream=True, headers={"User-Agent": UA_MOBILE})
    r.raise_for_status()
    with open(dest_path, "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            if chunk: f.write(chunk)

def sanitize(s):
    return re.sub(r"[^a-zA-Z0-9_.-]+", "_", s or "")

def cmd_download_profile(a):
    # Avviso legale
    print("⚠️  ATTENZIONE: scaricare contenuti può violare i ToS e i diritti d'autore.")
    print("Usa solo se hai titolo/consenso/legittimo interesse. Procedo tra 2s…")
    time.sleep(2)

    cfg = load_config()
    sid = ensure_sessionid(cfg.get("sessionid"))
    s = mk_session(sid)

    username = a.username.strip().lstrip("@")
    # info utente + id numerico
    u_info = get_profile_by_username(s, username)
    if not u_info.get("id"): raise UITError("Impossibile ricavare ID utente.")
    user_id = str(u_info["id"])

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    base = Path.home() / "OSINT Tool" / "intagram" / "downloads" / f"{sanitize(username)}_{ts}"
    base.mkdir(parents=True, exist_ok=True)
    manifest = base / "manifest.txt"

    # salva foto profilo (se disponibile in HD da user_info_by_id)
    try:
        u_full = get_user_info_by_id(s, user_id)
        ppic = u_full.get("profile_pic_url") or u_info.get("profile_pic_url")
        if ppic:
            download_url(s, ppic, base / "profile.jpg")
    except Exception as e:
        print(f"⚠️  Foto profilo non scaricata: {e}")

    # scrivi header manifest
    with open(manifest, "w", encoding="utf-8") as f:
        f.write(f"DOWNLOAD PROFILO — @{username} (id={user_id}) — {ts}\n")
        f.write("Nota: rispettare ToS e diritti. Solo per uso lecito.\n\n")

    # itera TUTTO il feed
    count = 0
    for item in iter_user_feed(s, user_id):
        media_type = item.get("media_type")  # 1=img, 2=video, 8=carousel
        code = item.get("code") or item.get("pk")
        taken_at = item.get("taken_at") or 0
        dt = datetime.datetime.utcfromtimestamp(int(taken_at)).strftime("%Y-%m-%d %H:%M:%S UTC") if taken_at else "N/D"
        caption = ""
        if item.get("caption"): caption = item["caption"].get("text") or ""
        shortcode = item.get("code") or ""
        link = f"https://www.instagram.com/p/{shortcode}/" if shortcode else "N/D"
        post_id = str(item.get("pk") or "")
        pretty = f"{post_id} | type={media_type} | {dt} | {link}"

        # salva nel manifest
        with open(manifest, "a", encoding="utf-8") as f:
            f.write(pretty + "\n")
            if caption: f.write("CAPTION: " + caption.replace("\n", " ")[:1000] + "\n")
            f.write("\n")

        # scarica contenuti
        try:
            if media_type == 1:  # image
                url = best_image_url(item)
                if url:
                    download_url(s, url, base / f"{post_id}.jpg")
            elif media_type == 2:  # video
                vurl = best_video_url(item) or best_image_url(item)
                if vurl and "mp4" in vurl:
                    download_url(s, vurl, base / f"{post_id}.mp4")
                elif vurl:
                    download_url(s, vurl, base / f"{post_id}.jpg")
            elif media_type == 8:  # carousel
                sidecars = item.get("carousel_media") or []
                idx = 1
                for sc in sidecars:
                    if sc.get("media_type") == 2:
                        vurl = best_video_url(sc) or best_image_url(sc)
                        if vurl and "mp4" in vurl:
                            download_url(s, vurl, base / f"{post_id}_{idx}.mp4")
                        elif vurl:
                            download_url(s, vurl, base / f"{post_id}_{idx}.jpg")
                    else:
                        url = best_image_url(sc)
                        if url:
                            download_url(s, url, base / f"{post_id}_{idx}.jpg")
                    idx += 1
            else:
                # fallback: prova immagine principale
                url = best_image_url(item)
                if url:
                    download_url(s, url, base / f"{post_id}.jpg")
        except requests.HTTPError as e:
            print(f"❌ Errore HTTP su {post_id}: {e}")
        except Exception as e:
            print(f"❌ Errore su {post_id}: {e}")

        count += 1
        # respiro per non farci limitare troppo
        time.sleep(0.3)

    print(f"✅ Download completato. File in: {base}")
    return 0

# ---------------- Comandi info + extra + export ----------------
def cmd_show_config(_):
    cfg = load_config(); sid = cfg.get("sessionid")
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(cfg.get("updated_at",0))) if cfg.get("updated_at") else "—"
    rows = [("SessionID", mask(sid) if sid else "NON CONFIGURATO"),
            ("Ultimo aggiornamento", when),
            ("Nota", "Se ricevi 401/403, riconfigura (il cookie può scadere).")]
    print_table(" Stato ", rows); return 0

def cmd_from_username(a):
    cfg = load_config(); sid = ensure_sessionid(cfg.get("sessionid")); s = mk_session(sid)
    u = get_profile_by_username(s, a.username)
    base_rows = [
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
        out = export_table(a.export, title, base_rows, mode="w")
        if a.include_extra:
            extra = collect_sensitive_fields(u)
            header = [("AVVISO", "Contiene campi sensibili: possibili limitazioni/blocchi dell'account del sessionID.")]
            export_table(a.export, " Avvertenza ", header)
            export_table(a.export, " Dati aggiuntivi da USERNAME ", extra if extra else [("Disponibilità","Nessun campo extra esposto")])
        print(f"📄 Salvato in: {out}")
    else:
        print_table(title, base_rows)
        if getattr(a, "extra", False):
            print(); 
            extra = collect_sensitive_fields(u)
            if extra: print_table(" Dati aggiuntivi (sensibili) da USERNAME ", extra)
            else: print_table(" Dati aggiuntivi (sensibili) da USERNAME ", [("Disponibilità","Nessun campo extra esposto")])
    return 0

def cmd_from_id(a):
    cfg = load_config(); sid = ensure_sessionid(cfg.get("sessionid")); s = mk_session(sid)
    u = get_user_info_by_id(s, a.user_id)
    base_rows = [
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
        out = export_table(a.export, title, base_rows, mode="w")
        if a.include_extra:
            extra = collect_sensitive_fields(u)
            header = [("AVVISO", "Contiene campi sensibili: possibili limitazioni/blocchi dell'account del sessionID.")]
            export_table(a.export, " Avvertenza ", header)
            export_table(a.export, " Dati aggiuntivi da ID ", extra if extra else [("Disponibilità","Nessun campo extra esposto")])
        print(f"📄 Salvato in: {out}")
    else:
        print_table(title, base_rows)
        if getattr(a, "extra", False):
            print();
            extra = collect_sensitive_fields(u)
            if extra: print_table(" Dati aggiuntivi (sensibili) da ID ", extra)
            else: print_table(" Dati aggiuntivi (sensibili) da ID ", [("Disponibilità","Nessun campo extra esposto")])
    return 0

# ---------------- Configurazione sessionID ----------------
GUIDE = """
PRIMA DI INIZIARE — ACCEDI AL TUO PROFILO INSTAGRAM
  1) Apri https://www.instagram.com (no incognito) e fai login.
  2) Lascia almeno una scheda di Instagram aperta.

ESTRAZIONE AUTOMATICA
  • Lettura 'sessionid' da Chrome/Chromium/Brave/Edge/Opera/Firefox (può chiedere sblocco keyring).

ESTRAZIONE MANUALE
  - Chrome/Chromium/Brave/Edge/Opera: F12 → Application → Storage → Cookies → https://www.instagram.com → sessionid (Value)
  - Firefox: F12 → Storage/Archiviazione → Cookies → https://www.instagram.com → sessionid (Value)

NOTE
  • Il sessionID può scadere (401/403) → riconfigura.
  • Input tipo 'sessionid=...;' viene pulito automaticamente.
""".strip()
def print_guide_banner():
    bar = "═"*70
    print(f"\n{bar}\nGUIDA CONFIGURAZIONE SESSIONID\n{bar}\n{GUIDE}\n{bar}\n")
def cmd_configure(a):
    print_guide_banner()
    cfg = load_config(); sid = None
    if a.auto:
        print("🔎 Tentativo automatico: lettura 'sessionid' dai browser…")
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
                except Exception: continue
                if sid: break
        except Exception: sid = None
        print("✅ Trovato automaticamente." if sid else "❌ Non trovato in automatico.")
    if not sid:
        raw = (a.sessionid or input("\nIncolla qui il sessionid (Value): ").strip())
        sid = normalize_sessionid(raw)
    if not sid: raise UITError("SessionID vuoto.")
    cfg["sessionid"] = sid; cfg["updated_at"] = int(time.time()); save_config(cfg)
    print(f"\n💾 Salvato. SessionID: {mask(sid)}")
    print("Suggerimento: con 401/403 esegui di nuovo la configurazione.\n"); return 0

# ---------------- Main parsers ----------------
def main():
    p = argparse.ArgumentParser(prog="uit", add_help=True)
    sub = p.add_subparsers(dest="cmd")

    pc = sub.add_parser("configure", help="Guida e configurazione del sessionID (auto/man)")
    pc.add_argument("--auto", action="store_true"); pc.add_argument("--sessionid")
    pc.set_defaults(func=cmd_configure)

    ps = sub.add_parser("show-config", help="Mostra sessionID oscurato e data")
    ps.set_defaults(func=cmd_show_config)

    pu = sub.add_parser("from-username", help="Lookup da username")
    pu.add_argument("username")
    pu.add_argument("--export", help="Percorso TXT per export")
    pu.add_argument("--include-extra", action="store_true", help="Include nel TXT i campi aggiuntivi (sensibili)")
    pu.add_argument("--extra", action="store_true", help="Mostra a schermo i campi aggiuntivi (sensibili)")
    pu.set_defaults(func=cmd_from_username)

    pi = sub.add_parser("from-id", help="Lookup da ID")
    pi.add_argument("user_id")
    pi.add_argument("--export", help="Percorso TXT per export")
    pi.add_argument("--include-extra", action="store_true", help="Include nel TXT i campi aggiuntivi (sensibili)")
    pi.add_argument("--extra", action="store_true", help="Mostra a schermo i campi aggiuntivi (sensibili)")
    pi.set_defaults(func=cmd_from_id)

    pd = sub.add_parser("download-profile", help="Scarica foto profilo e TUTTI i post dell'utente")
    pd.add_argument("username", help="Username del profilo (senza @)")
    pd.set_defaults(func=cmd_download_profile)

    args = p.parse_args()
    if not args.cmd: p.print_help(); return 0
    try: return args.func(args)
    except UITError as e: print(f"❌ {e}", file=sys.stderr); return 2
    except requests.HTTPError as e: print(f"❌ HTTP error: {e}", file=sys.stderr); return 3
    except KeyboardInterrupt: print("Interrotto."); return 130

if __name__ == "__main__": sys.exit(main())
PY
chmod +x "$PY"

# === Launcher con MENU, export unico, extra sensibili e SCARICA PROFILO INTERO ===
cat > "$LAUNCH" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/OSINT Tool/intagram"
VENV="$BASE/.venv"
PY="$BASE/uit.py"

DESKTOP_DIR="$HOME/Desktop"
if [ -f "$HOME/.config/user-dirs.dirs" ]; then
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
  echo "3) Ottieni altre informazioni (sensibili)"
  read -rp "Seleziona: " POST
  case "${POST:-}" in
    2)
      local mode="$1"  # username | id
      local val="$2"
      local safe; safe="$(echo "$val" | tr -cd '[:alnum:]_.-')"; [ -n "$safe" ] || safe="output"
      local ts; ts="$(date +%Y%m%d_%H%M%S)"
      local out="${DESKTOP_DIR}/${mode}_${safe}_${ts}.txt"
      echo "Includere anche i dati aggiuntivi (sensibili)? Questo può comportare limitazioni/blocchi del tuo account (sessionID). [y/N]"
      read -r INC
      echo ">> Salvo in: $out"
      if [ "$mode" = "username" ]; then
        if [[ "${INC:-N}" =~ ^[Yy]$ ]]; then
          "$PY" from-username "$val" --export "$out" --include-extra
        else
          "$PY" from-username "$val" --export "$out"
        fi
      else
        if [[ "${INC:-N}" =~ ^[Yy]$ ]]; then
          "$PY" from-id "$val" --export "$out" --include-extra
        else
          "$PY" from-id "$val" --export "$out"
        fi
      fi
      echo "✔️  File creato."
      read -rp $'\n[Invio per continuare] ' _
      ;;
    3)
      echo
      echo "⚠️  ATTENZIONE: i campi richiesti possono essere considerati sensibili."
      echo "Instagram può limitare o bloccare l'account associato al sessionID."
      read -rp "Procedere comunque? [y/N] " CONF
      if [[ "${CONF:-N}" =~ ^[Yy]$ ]]; then
        if [ "$1" = "username" ]; then
          clear; "$PY" from-username "$2" --extra || true
        else
          clear; "$PY" from-id "$2" --extra || true
        fi
        echo; read -rp $'\n[Invio per continuare] ' _
      fi
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
  echo "[6] Scarica profilo intero (foto/video)"
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
      read -r ANS; ANS="${ANS:-Y}"
      if [[ "$ANS" =~ ^[Yy]$ ]]; then "$PY" configure --auto || true; fi
      echo; echo "Se l'auto non ha trovato nulla, incolla manualmente il valore del cookie sessionid."
      "$PY" configure || true
      read -rp $'\n[Invio per continuare] ' _
      ;;
    2)
      read -rp "Inserisci USERNAME (senza @): " U
      [ -n "${U:-}" ] || { echo "Username vuoto."; read -rp $'\n[Invio per continuare] ' _; continue; }
      clear; "$PY" from-username "$U" || true
      post_menu "username" "$U"
      ;;
    3)
      read -rp "Inserisci ID numerico: " ID
      [ -n "${ID:-}" ] || { echo "ID vuoto."; read -rp $'\n[Invio per continuare] ' _; continue; }
      clear; "$PY" from-id "$ID" || true
      post_menu "id" "$ID"
      ;;
    4)
      clear; "$PY" show-config || true
      echo; read -rp $'\n[Invio per continuare] ' _
      ;;
    5)
      clear; bash "$BASE/update.sh" || true
      echo; read -rp $'\n[Invio per continuare] ' _
      ;;
    6)
      read -rp "USERNAME (senza @) da scaricare interamente: " U
      [ -n "${U:-}" ] || { echo "Username vuoto."; read -rp $'\n[Invio per continuare] ' _; continue; }
      clear
      "$PY" download-profile "$U" || true
      echo; read -rp $'\n[Invio per continuare] ' _
      ;;
    0)
      echo "Ciao!"; exit 0
      ;;
    *)
      echo "Opzione non valida."; read -rp $'\n[Invio per continuare] ' _
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
source "$VENV/bin/activate"
python -m pip install -U pip wheel >/dev/null
python -m pip install --no-cache-dir -U requests browser_cookie3 >/dev/null
python -m py_compile "$PY"
echo "✔️  Aggiornamento completato."
BASH
chmod +x "$UPDATE"

# Alias
if ! grep -q 'alias intagram=' "$BASHRC"; then
  echo "alias intagram='bash \"$LAUNCH\"'" >> "$BASHRC"
  echo ">> Alias 'intagram' aggiunto a ~/.bashrc"
fi

deactivate || true
echo; echo "=== Installazione completata ==="
echo "Cartella: $APPDIR"
echo "Usa:  source \"$BASHRC\" && intagram"
