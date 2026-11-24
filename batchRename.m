function batchRename(baseDir, vidname)
% batchRename Rename each experiment's video to match its folder name.
%   baseDir is the parent directory containing the experiment folders.
%   vidname is the current video filename, including its extension.
%
%   For example, batchRename('data', 'video.mp4') renames
%   data/Exp01/compressed/video.mp4 to data/Exp01/compressed/Exp01.mp4.
%   Missing source files are skipped silently. Existing target files are kept.

% List immediate subfolders, excluding the current (.) and parent (..) entries.
folders = dir(baseDir);
folders = folders([folders.isdir]);
folders = folders(~ismember({folders.name}, {'.', '..'}));

% Keep the original extension, including the leading dot (e.g., '.mp4').
[~, ~, ext] = fileparts(vidname);
for iFile = 1:length(folders)
    expName = folders(iFile).name;
    % Build both paths inside this experiment's compressed folder.
    oldFile = fullfile(baseDir, expName, 'compressed', vidname);
    newFile = fullfile(baseDir, expName, 'compressed', [expName ext]);
    % Rename the source only if it exists and the target filename is available.
    if isfile(oldFile)
        if ~isfile(newFile)
            movefile(oldFile, newFile);
            fprintf('Renamed: %s -> %s\n', vidname, [expName ext]);
        else
            fprintf('Skipped (target already exists): %s\n', newFile);
        end%if
    end%if
end%iFile

disp('Done!');

end