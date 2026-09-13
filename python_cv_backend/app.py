import os
import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from ultralytics import YOLO

app = FastAPI(title="HerCycle LH Strip CV Pipeline", version="1.0")

# Load trained YOLO model
MODEL_PATH = os.getenv("MODEL_PATH", "../assets/best.pt")
if not os.path.exists(MODEL_PATH):
    # Fallback to local asset path if running inside python_cv_backend dir
    MODEL_PATH = "assets/best.pt"

print(f"Loading YOLO model from {MODEL_PATH}...")
try:
    model = YOLO(MODEL_PATH)
except Exception as e:
    print(f"Warning: Could not load model at startup: {e}")
    model = None

def get_clinical_dye_volume(center_x, center_y, box_height, green_channel):
    fixed_width = 10
    h, w = green_channel.shape
    px1, px2 = max(0, int(center_x - fixed_width)), min(w, int(center_x + fixed_width))
    py1, py2 = max(0, int(center_y - box_height/2)), min(h, int(center_y + box_height/2))
    
    crop = green_channel[py1:py2, px1:px2].astype(np.float64)
    if crop.size == 0: 
        return 0.01, (px1, py1, px2, py2)
    
    linear_crop = np.power(crop / 255.0, 2.2)
    local_bg = float(np.percentile(linear_crop, 85))
    if local_bg <= 0: 
        local_bg = 1.0
        
    linear_crop[linear_crop <= 0] = 1.0
    light_ratio = local_bg / linear_crop
    light_ratio[light_ratio < 1.0] = 1.0
    
    od_array = np.log10(light_ratio)
    total_dye_od = np.sum(od_array)
    
    return max(0.001, float(total_dye_od)), (px1, py1, px2, py2)

@app.post("/api/analyze-lh-strip")
async def analyze_lh_strip(file: UploadFile = File(...)):
    if model is None:
        raise HTTPException(status_code=500, detail="YOLO model not loaded on backend server.")
    
    try:
        contents = await file.read()
        nparr = np.frombuffer(contents, np.uint8)
        img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
        if img is None:
            raise HTTPException(status_code=400, detail="Invalid image file decode failed.")
        
        green_channel = img[:, :, 1]
        results = model(img, conf=0.15)
        
        raw_detections = []
        for box in results[0].boxes:
            conf = float(box.conf[0])
            x1, y1, x2, y2 = map(int, box.xyxy[0].cpu().numpy())
            cx = (x1 + x2) / 2
            cy = (y1 + y2) / 2
            raw_detections.append({'cx': cx, 'cy': cy, 'h': y2-y1, 'x1': x1, 'conf': conf})
            
        raw_detections = sorted(raw_detections, key=lambda k: k['conf'], reverse=True)
        
        unique_lines = []
        min_pixel_distance = 40 
        
        for line in raw_detections:
            is_duplicate = False
            for u_line in unique_lines:
                if abs(line['cx'] - u_line['cx']) < min_pixel_distance:
                    is_duplicate = True
                    break
            if not is_duplicate:
                unique_lines.append(line)
                
        top_2_lines = unique_lines[:2]
        
        c_center, t_center = None, None
        if len(top_2_lines) == 2:
            top_2_lines = sorted(top_2_lines, key=lambda k: k['x1'])
            t_center, c_center = top_2_lines[0], top_2_lines[1]
        elif len(top_2_lines) == 1:
            c_center = top_2_lines[0]
            
        c_volume = 1.0
        if c_center is not None:
            c_volume, _ = get_clinical_dye_volume(c_center['cx'], c_center['cy'], c_center['h'], green_channel)
            
        t_volume = 0.0
        if t_center is not None:
            t_volume, _ = get_clinical_dye_volume(t_center['cx'], t_center['cy'], t_center['h'], green_channel)
            
        raw_ratio = t_volume / c_volume
        
        raw_anchors =      [0.00, 0.17, 0.40, 0.59, 1.01, 1.03, 2.00]
        clinical_targets = [0.00, 0.32, 0.54, 0.90, 0.93, 1.15, 2.20]
        
        calibrated_ratio = float(np.interp(raw_ratio, raw_anchors, clinical_targets))
        
        # Surge status mapping
        if calibrated_ratio >= 1.15:
            surge_status = "PEAK"
        elif calibrated_ratio >= 0.8:
            surge_status = "HIGH"
        elif calibrated_ratio >= 0.3:
            surge_status = "RISING"
        else:
            surge_status = "LOW"

        return JSONResponse(content={
            "success": True,
            "raw_ratio": round(raw_ratio, 3),
            "calibrated_ratio": round(calibrated_ratio, 3),
            "surge_status": surge_status,
            "detections_count": len(unique_lines),
            "model_version": "YOLO-LH-v1",
            "calibration_version": "LH-CAL-v1"
        })
        
    except Exception as e:
        return JSONResponse(status_code=500, content={"success": False, "error": str(e)})

@app.get("/health")
def health():
    return {"status": "healthy", "model_loaded": model is not None}
