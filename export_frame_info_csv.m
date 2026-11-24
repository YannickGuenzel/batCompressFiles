%% export_frame_info_csv
% This small MATLAB script finds experiment folders containing
% metadata.yaml, combines frame numbers and timestamps from their .npz
% files, and saves a CSV sorted by frame number in each folder.
% 
% Required external code:
% https://github.com/kwikteam/npy-matlab
clear all; close all; clc

npyMatlabFolder = '...\GitHub\npy-matlab';  % Set this if readNPY is not on the path.

%% Settings

% Export one <experiment>_frameinfo.csv per folder containing metadata.yaml.
mainFolder = '...';

%% Process
% Load the NPY reader if it is missing from the MATLAB path.
if isempty(which('readNPY'))
    % Locate the toolbox and verify that MATLAB can find readNPY.
    assert(isfolder(npyMatlabFolder), 'Set npyMatlabFolder to your npy-matlab installation.');
    addpath(genpath(npyMatlabFolder));
    assert(~isempty(which('readNPY')), 'Could not find readNPY in %s.', npyMatlabFolder);
end
% Check the search root before looking for experiments.
assert(isfolder(mainFolder), 'Experiment root does not exist: %s', mainFolder);

% Each metadata file identifies an experiment folder.
matches = dir(fullfile(mainFolder, '**', 'metadata.yaml'));
matches = matches(~[matches.isdir]);
experimentFolders = unique({matches.folder});

% Process each experiment in its own folder.
for iFolder = 1:numel(experimentFolders)
    % Find the NPZ chunks directly inside this experiment folder.
    folderPath = experimentFolders{iFolder};
    files = dir(fullfile(folderPath, '*.npz'));
    files = files(~[files.isdir]);
    % Skip experiments that have no chunks to export.
    if isempty(files)
        % Report the empty folder and move on to the next experiment.
        warning('Skipping folder with no NPZ files: %s', folderPath);
        continue
    end

    % Collect each chunk separately, then concatenate once per experiment.
    numbers = cell(numel(files), 1);
    times = cell(numel(files), 1);
    % Read the paired arrays from each chunk.
    for iFile = 1:numel(files)
        % Resolve the archive path and store its arrays at the same index.
        npzPath = fullfile(folderPath, files(iFile).name);
        [numbers{iFile}, times{iFile}] = readFrameChunk(npzPath);
    end
    % Combine the chunks into a table with one row per frame.
    frameInfo = table(vertcat(numbers{:}), vertcat(times{:}), ...
        'VariableNames', {'frame_number', 'frame_time'});

    % Sort whole rows to keep each frame paired with its timestamp.
    % Gaps are retained. Duplicate frame numbers indicate overlapping chunks.
    frameInfo = sortrows(frameInfo, 'frame_number');
    assert(all(diff(frameInfo.frame_number) > 0), ...
        'Duplicate frame numbers in %s. Check for overlapping chunks.', folderPath);

    % Save the CSV alongside the NPZ files, using the experiment folder name.
    [~, baseName, suffix] = fileparts(folderPath);
    csvPath = fullfile(folderPath, [baseName suffix '_frameinfo.csv']);
    writetable(frameInfo, csvPath);
    fprintf('Wrote %d frames to %s\n', height(frameInfo), csvPath);
end%iFolder

% Read and validate the frame index from one NPZ archive.
function [numbers, times] = readFrameChunk(npzPath)
    % Use a fresh directory and remove it even if reading the chunk fails.
    tmpFolder = tempname;
    mkdir(tmpFolder);
    cleanup = onCleanup(@() rmdir(tmpFolder, 's')); %#ok<NASGU>
    unzip(npzPath, tmpFolder);

    % Read both arrays and check that each frame has one timestamp.
    numbers = readNPY(fullfile(tmpFolder, 'frame_number.npy'));
    times = readNPY(fullfile(tmpFolder, 'frame_time.npy'));
    assert(isvector(numbers) && isvector(times) && numel(numbers) == numel(times), ...
        'Expected one timestamp per frame in %s.', npzPath);

    % Normalize both arrays to columns before merging chunks.
    numbers = numbers(:);
    times = times(:);
end%FCN:readFrameChunk
