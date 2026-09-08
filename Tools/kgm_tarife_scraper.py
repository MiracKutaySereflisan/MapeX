#!/usr/bin/env python3
"""
KGM / Kuzey Marmara otoyol tarife PDF'lerini uygulamanın okuduğu JSON'a çevirir.

NEDEN UYGULAMA İÇİNDE DEĞİL
---------------------------
PDF ayrıştırma kırılgandır: gömülü font kodlaması, sütun hizası ve sayfa düzeni
her yayında değişebilir. Bunu telefonda, sürüş sırasında çalıştırmak anlamsız —
tarife yılda 1–2 kez değişiyor. Doğru yer burası: bir kez çalıştır, çıkan JSON'u
bir yere koy, uygulamanın Ayarlar > Geçiş Ücretleri > "Uzaktan Tarife" alanına
o adresi yaz.

KULLANIM
--------
    pip install pypdf requests
    python3 kgm_tarife_scraper.py --out tarife.json

    # tek bir PDF'i incelemek için (sütun adlarını görmek üzere):
    python3 kgm_tarife_scraper.py --dump https://.../Anadolu_Otoyolu_2026.pdf

DİKKAT — ARAÇ SINIFI TUZAĞI
---------------------------
İşletmeciler AYNI numarayı farklı araçlara veriyor:
  • KGM (köprüler)          : 1. sınıf = OTOMOBİL
  • Kuzey Marmara Otoyolu   : 1. sınıf = MOTOSİKLET, otomobil 2. SINIF
Yanlış sütunu okumak 3 katı hataya yol açar. `--auto-class` bunu, satırdaki
fiyat sıralamasına bakarak tahmin eder; yine de çıktıyı gözle doğrula.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone

try:
    from pypdf import PdfReader
except ImportError:
    print("pypdf gerekli:  pip install pypdf", file=sys.stderr)
    raise

import urllib.request

# Resmî kaynaklar. Yeni işletme yılında bu adresler değişebilir; sayfadan
# güncel PDF bağlantısını alıp buraya yaz.
SOURCES = {
    "kmo_anadolu": {
        "name": "Kuzey Marmara Otoyolu (Anadolu)",
        "url": "https://www.kuzeymarmaraotoyolu.com/Content/files/anadolu-yeni-fiyat/Anadolu_Otoyolu_2026.pdf",
        # KMO'da otomobil 2. sınıftır
        "automobile_column": 2,
    },
    # Avrupa kesiminin PDF adresini işletmeci sayfasından alıp ekleyin:
    # "kmo_avrupa": {...}
}

PRICE_RE = re.compile(r"\d{1,3}(?:[.,]\d{1,2})?")


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def pdf_lines(data: bytes):
    import io
    reader = PdfReader(io.BytesIO(data))
    for page in reader.pages:
        text = page.extract_text() or ""
        for line in text.splitlines():
            line = line.strip()
            if line:
                yield line


def parse_matrix(lines, automobile_column: int):
    """
    Satır biçimi tipik olarak:
        GİRİŞ_GİŞE  ÇIKIŞ_GİŞE  fiyat1  fiyat2  fiyat3 ...
    Fiyat sütunlarından `automobile_column`. olan alınır (1 tabanlı).
    """
    pairs = []
    for line in lines:
        prices = PRICE_RE.findall(line)
        if len(prices) < automobile_column:
            continue
        # Fiyatlardan önceki kısım gişe adlarıdır
        head = PRICE_RE.split(line)[0].strip()
        names = [n for n in re.split(r"\s{2,}|\t", head) if n]
        if len(names) < 2:
            continue
        try:
            fee = float(prices[automobile_column - 1].replace(",", "."))
        except ValueError:
            continue
        if fee <= 0:
            continue
        pairs.append({"from": names[0], "to": names[1], "fee": fee})
    return pairs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tarife.json")
    ap.add_argument("--dump", help="Tek bir PDF'in ham satırlarını yazdır")
    args = ap.parse_args()

    if args.dump:
        for line in pdf_lines(fetch(args.dump)):
            print(line)
        return

    corridors = []
    for key, src in SOURCES.items():
        print(f"→ {src['name']}", file=sys.stderr)
        try:
            data = fetch(src["url"])
            pairs = parse_matrix(pdf_lines(data), src["automobile_column"])
        except Exception as exc:
            print(f"  atlandı: {exc}", file=sys.stderr)
            continue

        if not pairs:
            print("  uyarı: hiç gişe çifti çıkarılamadı — PDF düzeni değişmiş "
                  "olabilir, --dump ile inceleyin", file=sys.stderr)
            continue

        print(f"  {len(pairs)} gişe çifti", file=sys.stderr)
        corridors.append({"key": key, "name": src["name"], "pairs": pairs})

    doc = {
        "version": datetime.now(timezone.utc).strftime("%Y.%m"),
        "validFrom": datetime.now(timezone.utc).isoformat(),
        "sourceNote": "KGM / işletmeci resmî tarife PDF'lerinden otomatik "
                      "çıkarıldı. Araç sınıfı sütunu gözle doğrulanmalıdır.",
        "gantryPairs": corridors,
    }

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    print(f"\nYazıldı: {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
