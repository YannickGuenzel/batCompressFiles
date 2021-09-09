# batCompressFiles
Batch file compressing of all .mp4 files in the current folder using ffmpeg
Compressed files will be saved in a new subfolder /compressed with the same filename.


## ffmpeg settings:
(can be changed via right click > edit > line 24)
-vcodec libx264		-	Video codec          (Lossless H.264)
-crf 20			-	constant rate factor (The range of the CRF scale is 0–51, where 0 is lossless, 23 is the default, and 51 is worst quality possible.)
-r 25			-	frame rate           (fps)