#!/usr/bin/env python3
"""
Скрипт скачивания изображений с галерейного сайта.

Логика:
1. Пользователь вводит ссылку вида https://site.com/g/3601564/6519838fc7/
2. На странице ищутся все ссылки, содержащие /s/xxxxx (страницы фото),
   домен таких ссылок может быть любым (относительные и абсолютные href).
3. На каждой такой странице ищется первая прямая ссылка на .webp в HTML
   (любой домен) и скачивается.
4. После обхода первой страницы галереи скрипт пробует пагинацию:
   .../?p=1, ?p=2, ?p=3, ?p=4 (домен галереи, тот же что ввёл юзер),
   пока сервер отвечает и на странице находятся новые /s/ ссылки.
"""

import argparse
import logging
import re
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("downloader")

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    )
}

# ссылки на страницы фото вида /s/xxxxx (домен любой, поэтому ищем
# и относительные href="/s/..." и абсолютные href="https://domen.com/s/...")
S_LINK_RE = re.compile(r'href="((?:https?://[^"]+)?/s/[^"]+)"')

# прямая ссылка на изображение: src="..." на любом сабдомене *.hath.network.
# Сама поддомен-часть перед hath.network случайная, поэтому фиксируем только
# домен верхнего уровня. Формат файла и имя не важны — берём любой файл.
IMG_LINK_RE = re.compile(
    r'src="(https?://[^"]+\.hath\.network/[^"]+\.[A-Za-z0-9]+)"',
    re.IGNORECASE,
)


def fetch(session: requests.Session, url: str, timeout: int = 20):
    try:
        resp = session.get(url, headers=HEADERS, timeout=timeout)
    except requests.RequestException as e:
        log.warning("Ошибка запроса %s: %s", url, e)
        return None
    if resp.status_code >= 400:
        log.info("Страница %s ответила %s", url, resp.status_code)
        return None
    return resp


def find_s_links(html: str, base_url: str) -> list[str]:
    links = set()
    for href in S_LINK_RE.findall(html):
        links.add(urljoin(base_url, href))
    return sorted(links)


def find_image_url(html: str) -> str | None:
    match = IMG_LINK_RE.search(html)
    if not match:
        return None
    return match.group(1)


def safe_filename(url: str, fallback_id: str) -> str:
    name = Path(urlparse(url).path).name
    if not name or "." not in name:
        name = f"{fallback_id}.jpg"
    return name


def download_image(session: requests.Session, img_url: str, out_dir: Path, fallback_id: str) -> bool:
    resp = fetch(session, img_url)
    if resp is None:
        return False
    filename = safe_filename(img_url, fallback_id)
    out_path = out_dir / filename
    # избегаем перезаписи при совпадении имён
    counter = 1
    stem, suffix = out_path.stem, out_path.suffix
    while out_path.exists():
        out_path = out_dir / f"{stem}_{counter}{suffix}"
        counter += 1
    out_path.write_bytes(resp.content)
    log.info("Скачано: %s (%d байт)", out_path.name, len(resp.content))
    return True


def process_s_page(session: requests.Session, s_url: str, out_dir: Path) -> bool:
    resp = fetch(session, s_url)
    if resp is None:
        return False
    img_url = find_image_url(resp.text)
    if not img_url:
        log.warning("Не найдено изображение на странице %s", s_url)
        return False
    fallback_id = Path(urlparse(s_url).path).name or "image"
    return download_image(session, img_url, out_dir, fallback_id)


def process_gallery_page(session: requests.Session, gallery_url: str, out_dir: Path, seen_s: set[str]) -> int:
    resp = fetch(session, gallery_url)
    if resp is None:
        return 0
    s_links = find_s_links(resp.text, gallery_url)
    new_links = [l for l in s_links if l not in seen_s]
    if not new_links:
        log.info("Новых ссылок /s/ на странице %s не найдено", gallery_url)
        return 0
    downloaded = 0
    for s_url in new_links:
        seen_s.add(s_url)
        log.info("Обработка: %s", s_url)
        if process_s_page(session, s_url, out_dir):
            downloaded += 1
    return downloaded


def build_paginated_url(base_gallery_url: str, page: int) -> str:
    base = base_gallery_url.rstrip("/") + "/"
    return f"{base}?p={page}"


def run(gallery_url: str, out_dir: Path, max_pages: int = 4) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    seen_s: set[str] = set()
    total = 0

    log.info("Стартовая страница галереи: %s", gallery_url)
    total += process_gallery_page(session, gallery_url, out_dir, seen_s)

    for page in range(1, max_pages + 1):
        page_url = build_paginated_url(gallery_url, page)
        log.info("Страница пагинации %d: %s", page, page_url)
        resp = fetch(session, page_url)
        if resp is None:
            log.info("Сервер не ответил на страницу %d, останавливаемся", page)
            break
        s_links = find_s_links(resp.text, page_url)
        new_links = [l for l in s_links if l not in seen_s]
        if not new_links:
            log.info("На странице %d новых фото нет, останавливаемся", page)
            break
        for s_url in new_links:
            seen_s.add(s_url)
            log.info("Обработка: %s", s_url)
            if process_s_page(session, s_url, out_dir):
                total += 1

    log.info("Готово. Всего скачано изображений: %d", total)


def main():
    parser = argparse.ArgumentParser(description="Скачивание изображений с галерейной страницы сайта")
    parser.add_argument("url", help="Ссылка на галерею, например https://site.com/g/3601564/6519838fc7/")
    parser.add_argument("-o", "--output", default="downloads", help="Папка для сохранения")
    parser.add_argument("--max-pages", type=int, default=4, help="Сколько страниц пагинации пробовать (?p=1..N)")
    args = parser.parse_args()

    if "/g/" not in args.url:
        log.warning("Ссылка не похожа на типовую (нет /g/), продолжаю всё равно")

    run(args.url, Path(args.output), max_pages=args.max_pages)


if __name__ == "__main__":
    main()
