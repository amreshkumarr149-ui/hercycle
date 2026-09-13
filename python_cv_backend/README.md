# HerCycle Python CV Microservice (YOLO + OpenCV)

This microservice wraps your trained YOLO model (`best.pt`) and OpenCV optical-density dye measurement pipeline into a FastAPI service that connects directly to the HerCycle Flutter app per PRD §37 & §38.

## Setup & Run

1. Place your trained model at `assets/best.pt` (or `../assets/best.pt`).
2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```
3. Run the server:
   ```bash
   uvicorn app:app --host 0.0.0.0 --port 8000 --reload
   ```

## Endpoint
- `POST /api/analyze-lh-strip`: Uploads an image file (`file`) and returns JSON with `raw_ratio`, `calibrated_ratio`, and `surge_status`.
