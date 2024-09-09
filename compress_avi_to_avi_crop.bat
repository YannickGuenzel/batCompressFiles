:: Turn off the command echoing feature
@echo off

:: Delayed Expansion will cause variables within a batch file to be expanded at execution time.
:: This allows to create and assign variables during a for-loop
setlocal enabledelayedexpansion

:: Create a folder for the compressed videos
mkdir compressed

:: Iterate over all files in the current folder that end with .mp4
for %%a IN ("*.avi") do (

	:: Get the current file name
	set FileName_In=%%a

	:: Cut of the file extension ".mp4", i.e. the last for characters of the string
	set FileName_In=!FileName_In:~0,-4!

	:: Concatenate original file name with "_compressed.mp4" to create the the output file's name
	set FileName_Out=!FileName_In!.avi

	:: Run ffmpeg
	:: crop=width:height:top_left_X:top_left_Y
	ffmpeg -err_detect ignore_err -i "%%a" -vcodec libx264 -crf 20 -r 25 -vf "crop=1500:1500:1175:1" "compressed\!FileName_OUT!"

)
pause