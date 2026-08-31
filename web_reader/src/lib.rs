use miniz_oxide::inflate::decompress_to_vec_zlib;
use wasm_bindgen::prelude::*;

const MAGIC: &[u8; 4] = b"LMF1";
const HEADER_SIZE: usize = 26;
const VERSION: u8 = 1;
const FORMAT_RGBA8888: u8 = 0;

#[wasm_bindgen]
pub struct LmfImage {
    width: u32,
    height: u32,
    count: u32,
    pixels: Vec<u8>,
}

#[wasm_bindgen]
impl LmfImage {
    #[wasm_bindgen(getter)]
    pub fn width(&self) -> u32 {
        self.width
    }

    /// Height of a single frame.
    #[wasm_bindgen(getter)]
    pub fn height(&self) -> u32 {
        self.height
    }

    #[wasm_bindgen(getter)]
    pub fn count(&self) -> u32 {
        self.count
    }

    /// Combined height of all frames stacked top to bottom.
    #[wasm_bindgen(getter, js_name = totalHeight)]
    pub fn total_height(&self) -> u32 {
        self.height * self.count
    }

    /// RGBA8888 pixel buffer, frames concatenated top to bottom.
    /// Sized width * totalHeight * 4.
    pub fn pixels(&self) -> Vec<u8> {
        self.pixels.clone()
    }
}

#[wasm_bindgen]
pub fn decode_lmf(data: &[u8]) -> Result<LmfImage, JsValue> {
    if data.len() < HEADER_SIZE {
        return Err(JsValue::from_str("Файл повреждён"));
    }
    if &data[0..4] != MAGIC {
        return Err(JsValue::from_str("Это не LMF-файл"));
    }
    if data[4] != VERSION {
        return Err(JsValue::from_str("Неподдерживаемая версия LMF"));
    }

    let count = read_u32le(data, 5);
    let width = read_u32le(data, 9);
    let height = read_u32le(data, 13);

    if data[17] != FORMAT_RGBA8888 {
        return Err(JsValue::from_str("Неподдерживаемый формат пикселя"));
    }

    let compressed_len = read_u64le(data, 18) as usize;
    let start = HEADER_SIZE;
    let end = start
        .checked_add(compressed_len)
        .ok_or_else(|| JsValue::from_str("Файл повреждён"))?;

    if data.len() < end {
        return Err(JsValue::from_str("Файл обрезан"));
    }

    let compressed = &data[start..end];
    let pixels = decompress_to_vec_zlib(compressed)
        .map_err(|_| JsValue::from_str("Ошибка распаковки данных"))?;

    let expected = (width as usize)
        .saturating_mul(height as usize)
        .saturating_mul(count as usize)
        .saturating_mul(4);

    if pixels.len() != expected {
        return Err(JsValue::from_str("Несоответствие размера данных"));
    }

    Ok(LmfImage {
        width,
        height,
        count,
        pixels,
    })
}

fn read_u32le(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]])
}

fn read_u64le(d: &[u8], o: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&d[o..o + 8]);
    u64::from_le_bytes(b)
}
