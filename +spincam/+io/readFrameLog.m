function T = readFrameLog(csvPath)
%READFRAMELOG Read a <base>_cam<serial>_frames.csv file into a typed table.
%   CameraID and TTL_Source are strings, HostTimestamp_datetime is a datetime in
%   the local time zone, all other columns are double.
arguments
    csvPath {mustBeTextScalar}
end
csvPath = spincam.internal.toWindowsPath(csvPath);
if ~isfile(csvPath)
    error('spincam:io:missingFile', 'File not found: %s', csvPath);
end
opts = delimitedTextImportOptions('Delimiter', ',', 'DataLines', [2 Inf], ...
    'VariableNamesLine', 1, 'VariableNamingRule', 'preserve');
header = strsplit(strtrim(fileread_firstline(csvPath)), ',');
opts.VariableNames = header;
types = repmat({'double'}, 1, numel(header));
types(ismember(header, {'CameraID', 'TTL_Source', 'HostTimestamp_datetime'})) = {'string'};
opts.VariableTypes = types;
T = readtable(csvPath, opts);
T.HostTimestamp_datetime = datetime(T.HostTimestamp_datetime, ...
    'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss.SSSSSSxxx', 'TimeZone', 'local', ...
    'Format', 'yyyy-MM-dd HH:mm:ss.SSSSSS');
end

function line = fileread_firstline(path)
fid = fopen(path, 'r');
if fid < 0
    error('spincam:io:openFailed', 'Cannot open %s.', path);
end
closer = onCleanup(@() fclose(fid));
line = fgetl(fid);
if ~ischar(line)
    error('spincam:io:empty', 'File %s is empty.', path);
end
end
