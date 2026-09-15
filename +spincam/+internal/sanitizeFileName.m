function name = sanitizeFileName(name)
%SANITIZEFILENAME Make a string safe to use as a Windows file-name component.
arguments
    name {mustBeTextScalar}
end
name = regexprep(char(name), '[<>:"/\\|?*\x00-\x1F]', '_');
name = regexprep(strtrim(name), '[\. ]+$', '');
if isempty(name)
    name = 'session';
end
end
