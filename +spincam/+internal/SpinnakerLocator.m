classdef SpinnakerLocator
    %SPINNAKERLOCATOR Find the Spinnaker .NET assemblies for any install folder or version.
    %   [s, problems] = spincam.internal.SpinnakerLocator.find() searches, in order:
    %     1. the environment variable SPINCAM_SPINNAKER_BIN
    %     2. the folder saved by spincam.setup('SpinnakerDir', folder) in spincam_config.json
    %     3. <Program Files>\Teledyne\Spinnaker, \FLIR Systems\Spinnaker, \Point Grey Research\Spinnaker
    %   Each folder may be the Spinnaker root, its bin64 folder, or a toolset folder such as
    %   bin64\vs2015. The SpinnakerNET_v<toolset>.dll with the highest toolset number below it
    %   wins, so newer Visual Studio builds of Spinnaker are picked up without code changes.
    %
    %   s has fields Folder, Source, Bin, SpinnakerNet, SpinVideoNet ('' when SpinVideo is not
    %   installed) and Toolset, or is [] when nothing was found. PROBLEMS lists explicitly
    %   configured folders (1 and 2) that do not contain the assemblies.

    methods (Static)
        function [s, problems] = find(opts)
            arguments
                opts.ConfigPath (1,:) char = spincam.internal.SpinnakerLocator.configPath()
                opts.Environment = getenv('SPINCAM_SPINNAKER_BIN')
                opts.DefaultRoots cell = spincam.internal.SpinnakerLocator.defaultRoots()
            end
            L = spincam.internal.SpinnakerLocator;
            s = [];
            problems = {};
            candidates = L.candidates('ConfigPath', opts.ConfigPath, 'Environment', opts.Environment, ...
                'DefaultRoots', opts.DefaultRoots);
            for k = 1:numel(candidates)
                found = L.inspect(candidates(k).Folder);
                if isempty(found)
                    if ~strcmp(candidates(k).Source, 'standard location')
                        problems{end + 1} = sprintf('%s points to %s, which contains no SpinnakerNET_v*.dll.', ...
                            candidates(k).Source, candidates(k).Folder); %#ok<AGROW>
                    end
                    continue
                end
                found.Source = candidates(k).Source;
                s = found;
                return
            end
        end

        function c = candidates(opts)
            arguments
                opts.ConfigPath (1,:) char = spincam.internal.SpinnakerLocator.configPath()
                opts.Environment = getenv('SPINCAM_SPINNAKER_BIN')
                opts.DefaultRoots cell = spincam.internal.SpinnakerLocator.defaultRoots()
            end
            c = struct('Folder', {}, 'Source', {});
            if ~isempty(opts.Environment)
                c(end + 1) = struct('Folder', char(opts.Environment), 'Source', 'SPINCAM_SPINNAKER_BIN');
            end
            cfg = spincam.internal.SpinnakerLocator.readConfig(opts.ConfigPath);
            if isfield(cfg, 'SpinnakerDir') && ~isempty(cfg.SpinnakerDir)
                c(end + 1) = struct('Folder', char(cfg.SpinnakerDir), 'Source', 'spincam_config.json');
            end
            for k = 1:numel(opts.DefaultRoots)
                c(end + 1) = struct('Folder', opts.DefaultRoots{k}, 'Source', 'standard location'); %#ok<AGROW>
            end
        end

        function s = inspect(folder)
            %INSPECT Assemblies in or below FOLDER ([] if none).
            s = [];
            folder = strtrim(char(folder));
            if isempty(folder)
                return
            end
            folder = spincam.internal.toWindowsPath(folder);
            if ~isfolder(folder)
                return
            end
            dirs = [{folder, fullfile(folder, 'bin64')}, subfolders(fullfile(folder, 'bin64')), subfolders(folder)];
            best = [];
            bestToolset = -1;
            for k = 1:numel(dirs)
                if ~isfolder(dirs{k})
                    continue
                end
                files = dir(fullfile(dirs{k}, 'SpinnakerNET_v*.dll'));
                for f = reshape(files, 1, [])
                    tok = regexpi(f.name, '^SpinnakerNET_v(\d+)\.dll$', 'tokens', 'once');
                    if isempty(tok)
                        continue
                    end
                    toolset = str2double(tok{1});
                    if toolset > bestToolset
                        bestToolset = toolset;
                        best = struct('Bin', dirs{k}, 'Name', f.name, 'Toolset', tok{1});
                    end
                end
            end
            if isempty(best)
                return
            end
            video = fullfile(best.Bin, ['SpinVideoNET_v' best.Toolset '.dll']);
            if ~isfile(video)
                alt = dir(fullfile(best.Bin, 'SpinVideoNET_v*.dll'));
                alt = alt(~cellfun(@isempty, regexpi({alt.name}, '^SpinVideoNET_v\d+\.dll$', 'once')));
                video = '';
                if ~isempty(alt)
                    video = fullfile(best.Bin, alt(1).name);
                end
            end
            s = struct('Folder', folder, 'Source', '', 'Bin', best.Bin, ...
                'SpinnakerNet', fullfile(best.Bin, best.Name), 'SpinVideoNet', video, 'Toolset', ['v' best.Toolset]);
        end

        function roots = defaultRoots()
            programFiles = {getenv('ProgramW6432'), getenv('ProgramFiles'), 'C:\Program Files'};
            programFiles = unique(programFiles(~cellfun(@isempty, programFiles)), 'stable');
            vendors = {'Teledyne\Spinnaker', 'FLIR Systems\Spinnaker', 'Point Grey Research\Spinnaker'};
            roots = {};
            for p = 1:numel(programFiles)
                for v = 1:numel(vendors)
                    roots{end + 1} = [programFiles{p} '\' vendors{v}]; %#ok<AGROW>
                end
            end
        end

        function p = configPath()
            %CONFIGPATH Machine-specific settings file in the project root (not versioned).
            p = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), 'spincam_config.json');
        end

        function cfg = readConfig(path)
            arguments
                path (1,:) char = spincam.internal.SpinnakerLocator.configPath()
            end
            cfg = struct();
            if ~isfile(path)
                return
            end
            try
                cfg = jsondecode(fileread(path));
            catch me
                warning('spincam:config:unreadable', 'Ignoring unreadable %s: %s', path, me.message);
                cfg = struct();
            end
        end

        function remember(folder, path)
            %REMEMBER Save FOLDER as SpinnakerDir, keeping other settings in the file.
            arguments
                folder {mustBeTextScalar}
                path (1,:) char = spincam.internal.SpinnakerLocator.configPath()
            end
            cfg = spincam.internal.SpinnakerLocator.readConfig(path);
            cfg.SpinnakerDir = spincam.internal.toWindowsPath(char(folder));
            fid = fopen(path, 'w');
            if fid < 0
                error('spincam:config:writeFailed', 'Cannot write %s.', path);
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, jsonencode(cfg, 'PrettyPrint', true), 'char');
        end
    end
end

function c = subfolders(d)
c = {};
if ~isfolder(d)
    return
end
listing = dir(d);
listing = listing([listing.isdir] & ~ismember({listing.name}, {'.', '..'}));
c = reshape(fullfile(d, {listing.name}), 1, []);
end
