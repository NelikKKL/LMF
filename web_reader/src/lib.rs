use miniz_oxide::inflate::decompress_to_vec_zlib;
use wasm_bindgen::prelude::*;

const MAGIC: &[u8; 4] = b"LMF1";
const HEADER_SIZE: usize = 26;
const VERSION: u8 = 2;
const FORMAT_RGBA8888: u8 = 0;
const BPP: usize = 4;

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

    /// RGBA8888 pixel buffer, frames concatenated top to bottom, already
    /// unfiltered back to plain pixels.
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
    let filtered_all = decompress_to_vec_zlib(compressed)
        .map_err(|_| JsValue::from_str("Ошибка распаковки данных"))?;

    let row_bytes = (width as usize) * BPP;
    let frame_filtered_size = (row_bytes + 1) * (height as usize);
    let expected = frame_filtered_size.saturating_mul(count as usize);

    if filtered_all.len() != expected {
        return Err(JsValue::from_str("Несоответствие размера данных"));
    }

    let mut pixels = vec![0u8; row_bytes * (height as usize) * (count as usize)];
    for i in 0..count as usize {
        let f_start = i * frame_filtered_size;
        let f_end = f_start + frame_filtered_size;
        let frame_pixels =
            unfilter_frame(&filtered_all[f_start..f_end], width as usize, height as usize);
        let out_start = i * row_bytes * (height as usize);
        pixels[out_start..out_start + frame_pixels.len()].copy_from_slice(&frame_pixels);
    }

    Ok(LmfImage {
        width,
        height,
        count,
        pixels,
    })
}

/// Reverses the PNG-style adaptive row filtering (None/Sub/Up/Average/Paeth)
/// applied by the Dart encoder. Layout: for each row, one filter-type byte
/// followed by row_bytes filtered bytes. Resets "previous row" to zero at
/// the top of the frame, matching the encoder.
fn unfilter_frame(filtered: &[u8], width: usize, height: usize) -> Vec<u8> {
    let row_bytes = width * BPP;
    let mut out = vec![0u8; row_bytes * height];

    let mut in_pos = 0usize;
    for y in 0..height {
        let filter_type = filtered[in_pos];
        in_pos += 1;
        let row_start = y * row_bytes;
        let prev_row_start = row_start.wrapping_sub(row_bytes);

        for i in 0..row_bytes {
            let fil = filtered[in_pos + i];
            let left = if i >= BPP { out[row_start + i - BPP] } else { 0 };
            let up = if y > 0 { out[prev_row_start + i] } else { 0 };

            let recon = match filter_type {
                0 => fil,
                1 => fil.wrapping_add(left),
                2 => fil.wrapping_add(up),
                3 => {
                    let avg = ((left as u16 + up as u16) / 2) as u8;
                    fil.wrapping_add(avg)
                }
                4 => {
                    let up_left = if y > 0 && i >= BPP {
                        out[prev_row_start + i - BPP]
                    } else {
                        0
                    };
                    fil.wrapping_add(paeth(left, up, up_left))
                }
                _ => fil,
            };
            out[row_start + i] = recon;
        }
        in_pos += row_bytes;
    }

    out
}

fn paeth(a: u8, b: u8, c: u8) -> u8 {
    let (a, b, c) = (a as i32, b as i32, c as i32);
    let p = a + b - c;
    let pa = (p - a).abs();
    let pb = (p - b).abs();
    let pc = (p - c).abs();
    if pa <= pb && pa <= pc {
        a as u8
    } else if pb <= pc {
        b as u8
    } else {
        c as u8
    }
}

fn read_u32le(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([d[o], d[o + 1], d[o + 2], d[o + 3]])
}

fn read_u64le(d: &[u8], o: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&d[o..o + 8]);
    u64::from_le_bytes(b)
}
