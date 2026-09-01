import os
import re
import sys
import time
from urllib.parse import urljoin, urlparse, urlunparse
from bs4 import BeautifulSoup
import requests

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
}

def create_folder_for_assets(base_url):
    path_parts = urlparse(base_url).path.strip("/").split("/")
    folder_name = path_parts[1] if len(path_parts) > 1 else "downloaded_images"
    os.makedirs(folder_name, exist_ok=True)
    return folder_name

def get_image_page_urls(page_url):
    print(f"🔍 Сканируем страницу: {page_url}")
    try:
        response = requests.get(page_url, headers=HEADERS, timeout=10)
        if response.status_code != 200:
            print(f"⚠️ Статус: {response.status_code}")
            return []
        soup = BeautifulSoup(response.text, "lxml")
        image_pages = []
        pattern = re.compile(r"/s/[a-zA-Z0-9]+/\d+-\d+|/s/[a-zA-Z0-9]+/\d+")
        for link in soup.find_all("a", href=True):
            href = link["href"]
            if pattern.search(href):
                full_url = urljoin(page_url, href)
                if full_url not in image_pages:
                    image_pages.append(full_url)
        return image_pages
    except Exception as e:
        print(f"❌ Ошибка {page_url}: {e}")
        return []

def download_image_from_page(page_url, folder):
    try:
        response = requests.get(page_url, headers=HEADERS, timeout=10)
        if response.status_code != 200:
            return
        soup = BeautifulSoup(response.text, "lxml")
        img_tags = soup.find_all("img")
        for img in img_tags:
            img_url = img.get("src") or img.get("data-src")
            if not img_url:
                continue
            if any(x in img_url.lower() for x in ["logo", "avatar", "icon", "banner", "loader"]):
                continue
            full_img_url = urljoin(page_url, img_url)
            img_name = os.path.basename(urlparse(full_img_url).path)
            if not img_name:
                continue
            save_path = os.path.join(folder, img_name)
            if os.path.exists(save_path):
                return
            print(f"📥 Скачиваем: {img_name}")
            img_data = requests.get(full_img_url, headers=HEADERS, timeout=15)
            if img_data.status_code == 200:
                with open(save_path, "wb") as f:
                    f.write(img_data.content)
                time.sleep(0.5)
                return
    except Exception as e:
        print(f"❌ Ошибка скачивания с {page_url}: {e}")

def modify_url_page(base_url, page_num):
    parsed_url = urlparse(base_url)
    new_query = f"p={page_num}"
    modified = parsed_url._replace(query=new_query)
    return urlunparse(modified)

if __name__ == "__main__":
    # Получаем ссылку из аргументов командной строки (переданных из GitHub Actions)
    if len(sys.argv) < 2:
        print("❌ Ошибка: Ссылка не передана!")
        sys.exit(1)
        
    input_url = sys.argv[1].strip()
    folder = create_folder_for_assets(input_url)
    print(f"📁 Папка для сохранения: {folder}\n")

    # Шаг 1: Первая страница
    image_pages = get_image_page_urls(input_url)
    for idx, img_page in enumerate(image_pages, start=1):
        download_image_from_page(img_page, folder)

    # Шаг 2: Страницы 1-4
    for p in range(1, 5):
        page_url = modify_url_page(input_url, p)
        try:
            res = requests.head(page_url, headers=HEADERS, timeout=5)
            if res.status_code != 200:
                break
        except requests.RequestException:
            break

        image_pages = get_image_page_urls(page_url)
        if not image_pages:
            break
        for idx, img_page in enumerate(image_pages, start=1):
            download_image_from_page(img_page, folder)

    print("\n🎉 Все изображения успешно скачаны.")