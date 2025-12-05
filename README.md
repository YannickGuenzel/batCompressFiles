# batCompressFiles
Batch file compressing of all .mp4 (compress_mp4_files.bat) or .avi (compress_avi_files.bat) files in the current folder using ffmpeg.
Compressed files will be saved in a new subfolder /compressed with the same filename.

## Configuration
(edit in "Configuration" section of the respective file):
- FFMPEG              : ffmpeg executable name or full path.
- INPUT_MASK          : glob for input files (e.g. .avi or .mp4).
- OUT_DIR             : output directory (relative to script directory).
- VIDEO_CODEC         : libx264, libsvtav1, h264_nvenc, av1_nvenc, or other ffmpeg encoder name.
- CRF                 : quality target.
- OVERWRITE_EXISTING  : 0 = skip existing outputs, 1 = overwrite them.
- ENABLE_CROP         : 0 = no crop, 1 = apply CROP_EXPR.
- CROP_EXPR           : ffmpeg crop expression (e.g. crop=1280:720:0:0).
- ENABLE_SCALE        : 0 = no scale, 1 = apply SCALE_EXPR.
- SCALE_EXPR          : ffmpeg scale expression (e.g. scale=1280:-1).
- DENOISE             : 0 = no denoise, 1 = add hqdn3d rule-of-thumb based on output size.
- SHARPEN             : 0 = no sharpen, 1 = add unsharp rule-of-thumb based on output size.
- ENABLE_CONCAT       : 0 = no concat, 1 = concat all successful outputs.
- CONCAT_OUTPUT_NAME  : final concatenated file name inside OUT_DIR.

## GetCropParameters
This small MATLAB script opens a video, shows its first frame for the user to click two points that define a rectangle to print a formatted bounding-box string for the configuration option "CROP_EXPR".