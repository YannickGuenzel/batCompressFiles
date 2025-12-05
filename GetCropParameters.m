%% GetCropParameters
% This script opens a video, shows its first frame for the user to click 
% two points that define a rectangle, builds a binary mask for that 
% rectangle, computes bounding-box properties, and prints a formatted
% bounding-box string.
clear; close all; clc; % Use clear instead of clear all for better performance

% Settings
% Set whether to accept rectangles (false) or use the center to enforece
% the result is a square.
SET.enforce_square = true;

% Prompt user to select a video file
[filename, pathname] = uigetfile({'*.mp4;*.avi'}, 'Select a video file');
if isequal(filename, 0) || isequal(pathname, 0)
    disp('User canceled the file selection.');
    return; % Exit if no file is selected
end

% Get first frame
videoObj = VideoReader(fullfile(pathname, filename));
img = single(rgb2gray(read(videoObj, 1)));

% Display the first frame
hFig = figure('Units', 'normalized', 'Position', [0 0 1 1]);
imagesc(img);
axis equal tight off;
colormap gray;

% Let user draw two points to define a rectangular region
disp('Please select two points to define a rectangle.');
XY = ginput(2);
close(hFig);

% Calculate rectangle boundaries
xMin = max(1, floor(min(XY(:, 1))));
xMax = min(videoObj.Width, ceil(max(XY(:, 1))));
yMin = max(1, floor(min(XY(:, 2))));
yMax = min(videoObj.Height, ceil(max(XY(:, 2))));

% Create a binary mask for the selected rectangle
mask = false(videoObj.Height, videoObj.Width);
mask(yMin:yMax, xMin:xMax) = true;

% Compute bounding box properties
props = regionprops(mask, 'BoundingBox');
if ~isempty(props)
    props = round(props.BoundingBox);
    if SET.enforce_square == true
        % Get parameters
        w = max([xMax-xMin, yMax-yMin]);
        h = max([xMax-xMin, yMax-yMin]);
        center = [xMin+w/2, yMin+h/2];
        corner = center - [w/2, h/2];
    else
        % Get parameters
        w = xMax-xMin;
        h = yMax-yMin;
        center = [xMin+w/2, yMin+h/2];
        corner = center - [w/2, h/2];
    end
    % Display bounding box [width:height:x:y] as strings
    disp([num2str(w), ':', num2str(h), ':', num2str(corner(1)), ':', num2str(corner(2))]);
else
    disp('No bounding box properties found.');
end
