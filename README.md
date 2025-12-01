# batCompressFiles
Batch file compressing of all .mp4 (compress_mp4_files.bat) or .avi (compress_avi_files.bat) files in the current folder using ffmpeg
Compressed files will be saved in a new subfolder /compressed with the same filename.

## Configuration
(edit in "Configuration" section of the respective file):
- FFMPEG              : ffmpeg executable name or full path.
- INPUT_MASK          : glob for input files.
- OUT_DIR             : output directory (relative to script directory).
- VIDEO_CODEC         : libsvtav1 (default, slow but better compression) or libx264.
- CRF                 : constant rate factor (0–51, lower = higher quality, 17-18 visually lossless, default = 23).
- FPS                 : output frame rate.
- OVERWRITE_EXISTING  : 0 = skip existing outputs, 1 = overwrite them (default).
- ENABLE_CROP         : 0 = no crop, 1 = apply CROP_EXPR.
- CROP_EXPR           : ffmpeg crop expression (e.g. crop=1280:720:0:0).
- ENABLE_SCALE        : 0 = no scale, 1 = apply SCALE_EXPR.
- SCALE_EXPR          : ffmpeg scale expression (e.g. scale=1280:-1).
- ENABLE_CONCAT       : 0 = no concat, 1 = concat all successful outputs.
- CONCAT_OUTPUT_NAME  : final concatenated file name inside OUT_DIR.