function T = mergeFrameLogs(folderOrRecording, baseName)
%MERGEFRAMELOGS Combine all camera frame logs of a recording, sorted by host time.
%   T = spincam.io.mergeFrameLogs(summary)          plan/summary from start/stopRecording
%   T = spincam.io.mergeFrameLogs(folder, baseName) every <camera>_<baseName>.csv frame log
%   in FOLDER, where baseName is summary.BaseName (e.g. 'mouse01_20260915_143012').
%   A Name column (the camera name, e.g. "topview") is added after CameraID.
arguments
    folderOrRecording
    baseName {mustBeTextScalar} = ''
end
if isstruct(folderOrRecording)
    files = {folderOrRecording.Cameras.CsvFile};
    cameraNames = {folderOrRecording.Cameras.Name};
else
    folder = spincam.internal.toWindowsPath(folderOrRecording);
    baseName = char(baseName);
    if isempty(baseName)
        error('spincam:io:missingBaseName', 'Give the recording base name (summary.BaseName).');
    end
    listing = dir(fullfile(folder, ['*_' baseName '.csv']));
    files = {};
    cameraNames = {};
    for k = 1:numel(listing)
        path = fullfile(listing(k).folder, listing(k).name);
        if isFrameLog(path)
            files{end + 1} = path; %#ok<AGROW>
            cameraNames{end + 1} = listing(k).name(1:end - numel(baseName) - 5); %#ok<AGROW>
        end
    end
    if isempty(files)
        error('spincam:io:missingFile', 'No frame logs matching *_%s.csv in %s.', baseName, folder);
    end
end
tables = cell(numel(files), 1);
for k = 1:numel(files)
    t = spincam.io.readFrameLog(files{k});
    tables{k} = addvars(t, repmat(string(cameraNames{k}), height(t), 1), 'After', 'CameraID', ...
        'NewVariableNames', 'Name');
end
T = vertcat(tables{:});
if any(strcmp(T.Properties.VariableNames, 'HostTime_s'))
    T = sortrows(T, {'HostTime_s', 'CameraID'});
else
    T = sortrows(T, {'HostTimestamp_datetime', 'CameraID'});
end
end

function tf = isFrameLog(path)
fid = fopen(path, 'r');
if fid < 0
    tf = false;
    return
end
closer = onCleanup(@() fclose(fid));
header = fgetl(fid);
tf = ischar(header) && startsWith(header, 'FrameNumber,CameraID,');
end
