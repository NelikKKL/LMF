import init, { decode_lmf } from "./pkg/lmf_reader.js";

const dropZone = document.getElementById("drop-zone");
const canvas = document.getElementById("canvas");
const emptyState = document.getElementById("empty-state");
const fileInput = document.getElementById("file-input");
const openBtn = document.getElementById("open-btn");
const errorBanner = document.getElementById("error-banner");
const errorText = document.getElementById("error-text");
const errorClose = document.getElementById("error-close");
const ctx = canvas.getContext("2d");

let wasmReady = init();

openBtn.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", () => {
  const file = fileInput.files[0];
  if (file) loadFile(file);
});

errorClose.addEventListener("click", () => (errorBanner.hidden = true));

["dragenter", "dragover"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.add("drag-over");
  })
);

["dragleave", "drop"].forEach((evt) =>
  dropZone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropZone.classList.remove("drag-over");
  })
);

dropZone.addEventListener("drop", (e) => {
  const file = e.dataTransfer.files[0];
  if (file) loadFile(file);
});

async function loadFile(file) {
  try {
    await wasmReady;
    const buffer = new Uint8Array(await file.arrayBuffer());
    const image = decode_lmf(buffer);

    canvas.width = image.width;
    canvas.height = image.totalHeight;

    const pixels = image.pixels();
    const imageData = new ImageData(
      new Uint8ClampedArray(pixels.buffer, pixels.byteOffset, pixels.length),
      image.width,
      image.totalHeight
    );
    ctx.putImageData(imageData, 0, 0);

    canvas.classList.add("visible");
    emptyState.classList.add("hidden");
    errorBanner.hidden = true;
  } catch (err) {
    showError(typeof err === "string" ? err : "Не удалось открыть файл");
  }
}

function showError(message) {
  errorText.textContent = message;
  errorBanner.hidden = false;
}
