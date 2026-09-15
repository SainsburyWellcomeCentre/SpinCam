function p = toWindowsPath(p)
%TOWINDOWSPATH Convert WSL-style paths to Windows paths.
%   '/mnt/c/Users/x'  -> 'C:\Users\x'
%   'C:/data/run1'    -> 'C:\data\run1'
%   Other paths (relative, UNC, already-Windows) are returned unchanged apart
%   from normalizing forward slashes after a drive letter.
arguments
    p {mustBeTextScalar}
end
p = char(p);
tokens = regexp(p, '^/mnt/([a-zA-Z])(/.*)?$', 'tokens', 'once');
if ~isempty(tokens)
    rest = tokens{2};
    p = [upper(tokens{1}) ':' strrep(rest, '/', '\')];
    if numel(p) == 2
        p = [p '\'];
    end
    return
end
if ~isempty(regexp(p, '^[a-zA-Z]:/', 'once'))
    p = strrep(p, '/', '\');
end
end
