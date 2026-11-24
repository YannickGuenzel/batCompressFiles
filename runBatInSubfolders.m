function runBatInSubfolders(mainFolder, batName)
% runBatInSubfolders Copy and run a Windows batch file in each immediatesubfolder.
%   mainFolder contains the source batch file, e.g., compress_mp4_files.bat
%   and the subfolders to process. batName is the batch filename, including
%   its extension.
%
%   Example:
%   runBatInSubfolders('C:\MyMainFolder', 'myscript.bat')

% Restore MATLAB's starting folder when the function exits, even after an error.
originalFolder = pwd;
restoreFolder = onCleanup(@() cd(originalFolder));

% Resolve mainFolder to an absolute path so it stays valid as cd changes
% the working folder during the loop.
cd(mainFolder);
mainFolder = pwd;
sourceBat = fullfile(mainFolder, batName);

% Stop before processing any subfolders if the source batch file is missing.
assert(isfile(sourceBat), 'Batch file not found: %s', sourceBat);

% Keep only immediate subfolders, excluding the current (.) and parent (..) entries.
folders = dir(mainFolder);
folders = folders([folders.isdir]);
folders = folders(~ismember({folders.name}, {'.', '..'}));

for iFile = 1:numel(folders)
    % Show which subfolder is being processed and its position in the list.
    targetFolder = fullfile(mainFolder, folders(iFile).name);
    fprintf('\nProcessing %d/%d: %s\n', ...
        iFile, numel(folders), targetFolder);

    % Copy the batch file into this subfolder, overwriting any existing copy.
    copyfile(sourceBat, fullfile(targetFolder, batName), 'f');

    % Run the batch file from this subfolder so relative paths resolve here.
    % Echo command output to MATLAB and capture the exit code in status.
    cd(targetFolder);
    status = system(sprintf('cmd /c call "%s"', batName), '-echo');

    % Report a nonzero exit code and continue with the next subfolder.
    if status ~= 0
        warning('Batch file failed in "%s" (exit code %d).', ...
            targetFolder, status);
    end%if
end%iFile
