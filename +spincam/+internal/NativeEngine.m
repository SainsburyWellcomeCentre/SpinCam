classdef NativeEngine
    %NATIVEENGINE Locate Spinnaker, build and load SpinCamEngine.dll.
    %   The engine is compiled from native/src with the C# 5 compiler of .NET Framework 4.8
    %   against the Spinnaker .NET assemblies found by spincam.internal.SpinnakerLocator, so it
    %   matches whichever Spinnaker version is installed. Without SpinVideoNET it is compiled
    %   with NO_SPINVIDEO and the SpinVideo formats are unavailable. The assemblies used are
    %   recorded in native/bin/SpinCamEngine.build.json: when the Spinnaker installation
    %   changes, the engine is stale and is rebuilt on the next load. .NET assemblies cannot
    %   be unloaded, so a rebuild after loading requires restarting MATLAB.

    properties (Constant)
        %VERIFIEDSPINNAKERVERSION Spinnaker version the hardware tests last passed with.
        VerifiedSpinnakerVersion = '4.2.0.83'
    end

    methods (Static)
        function root = projectRoot()
            root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
        end

        function p = dllPath()
            p = fullfile(spincam.internal.NativeEngine.projectRoot(), 'native', 'bin', 'SpinCamEngine.dll');
        end

        function p = stampPath()
            p = fullfile(spincam.internal.NativeEngine.projectRoot(), 'native', 'bin', 'SpinCamEngine.build.json');
        end

        function p = sourceDir()
            p = fullfile(spincam.internal.NativeEngine.projectRoot(), 'native', 'src');
        end

        function [s, problems] = spinnaker()
            %SPINNAKER Spinnaker assemblies to use ([] if not found); see SpinnakerLocator.find.
            [s, problems] = spincam.internal.SpinnakerLocator.find();
        end

        function d = spinnakerBin()
            %SPINNAKERBIN Folder with the Spinnaker .NET assemblies ('' if not found).
            s = spincam.internal.NativeEngine.spinnaker();
            d = '';
            if ~isempty(s)
                d = s.Bin;
            end
        end

        function p = compilerPath()
            windir = getenv('WINDIR');
            if isempty(windir)
                windir = 'C:\Windows';
            end
            p = fullfile(windir, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
        end

        function tf = isStale()
            %ISSTALE True when the DLL is missing, older than a source, or built against other assemblies.
            E = spincam.internal.NativeEngine;
            dll = dir(E.dllPath());
            if isempty(dll)
                tf = true;
                return
            end
            sources = dir(fullfile(E.sourceDir(), '*.cs'));
            tf = any([sources.datenum] > dll.datenum);
            s = E.spinnaker();
            if ~tf && ~isempty(s)
                tf = ~strcmp(E.readStamp(), E.stampFor(s));
            end
        end

        function tf = isLoaded()
            tf = ~isempty(spincam.internal.NativeEngine.state('loadedBin'));
        end

        function d = loadedBin()
            %LOADEDBIN Spinnaker folder this MATLAB session loaded ('' if not loaded).
            d = spincam.internal.NativeEngine.state('loadedBin');
        end

        function report = build(force)
            %BUILD Compile native/src/*.cs into native/bin/SpinCamEngine.dll.
            arguments
                force (1,1) logical = false
            end
            E = spincam.internal.NativeEngine;
            report = '';
            if ~force && ~E.isStale()
                return
            end
            if ~ispc
                error('spincam:engine:notWindows', 'The spincam engine requires Windows.');
            end
            if E.isLoaded()
                error('spincam:engine:loaded', ['SpinCamEngine.dll is already loaded in this MATLAB ' ...
                    'session and cannot be replaced. Restart MATLAB, then run spincam.setup(''ForceBuild'', true).']);
            end
            s = E.spinnaker();
            if isempty(s)
                E.errorNoSpinnaker();
            end
            report = E.compileTo(E.dllPath(), s, ~isempty(s.SpinVideoNet));
            fid = fopen(E.stampPath(), 'w');
            if fid >= 0
                fwrite(fid, E.stampFor(s), 'char');
                fclose(fid);
            end
        end

        function report = compileTo(outPath, s, withSpinVideo)
            %COMPILETO Compile native/src into OUTPATH against the assemblies in S (errors on failure).
            arguments
                outPath (1,:) char
                s (1,1) struct
                withSpinVideo (1,1) logical = ~isempty(s.SpinVideoNet)
            end
            E = spincam.internal.NativeEngine;
            csc = E.compilerPath();
            if ~isfile(csc)
                error('spincam:engine:noCompiler', 'C# compiler not found at %s (.NET Framework 4.x).', csc);
            end
            outDir = fileparts(outPath);
            if ~isfolder(outDir)
                mkdir(outDir);
            end
            references = sprintf('/reference:"%s"', s.SpinnakerNet);
            defines = '';
            if withSpinVideo
                references = sprintf('%s /reference:"%s"', references, s.SpinVideoNet);
            else
                defines = ' /define:NO_SPINVIDEO';
            end
            % Unquoted compiler path keeps cmd.exe from stripping the first quote pair.
            cmd = sprintf('%s /nologo /target:library /platform:x64 /unsafe /optimize+%s /out:"%s" %s "%s"', ...
                csc, defines, outPath, references, fullfile(E.sourceDir(), '*.cs'));
            [status, report] = system(cmd);
            if status ~= 0
                error('spincam:engine:buildFailed', 'Engine build failed:\n%s', report);
            end
        end

        function load()
            %LOAD Load the Spinnaker assemblies and the engine (building it if needed).
            E = spincam.internal.NativeEngine;
            if E.isLoaded()
                return
            end
            if ~ispc || ~NET.isNETSupported
                error('spincam:engine:noDotNet', 'spincam requires MATLAB on Windows with .NET Framework support.');
            end
            s = E.spinnaker();
            if isempty(s)
                E.errorNoSpinnaker();
            end
            % Native Spinnaker DLLs are resolved through PATH by the Windows loader.
            pathValue = getenv('PATH');
            if ~contains(lower(pathValue), lower(s.Bin))
                setenv('PATH', [s.Bin ';' pathValue]);
            end
            NET.addAssembly(s.SpinnakerNet);
            if ~isempty(s.SpinVideoNet)
                NET.addAssembly(s.SpinVideoNet);
            end
            if E.isStale()
                E.build(false);
            end
            NET.addAssembly(E.dllPath());
            SpinCam.AssemblyResolver.Register(s.Bin);
            E.state('loadedBin', s.Bin);
        end

        function tf = hasSpinVideo()
            %HASSPINVIDEO True when the loaded engine can write SpinVideo formats.
            spincam.internal.NativeEngine.load();
            tf = logical(SpinCam.Engine.HasSpinVideo);
        end

        function v = engineVersion()
            spincam.internal.NativeEngine.load();
            v = char(SpinCam.Engine.Version);
        end
    end

    methods (Static, Access = private)
        function value = state(name, newValue)
            persistent values
            if isempty(values)
                values = struct('loadedBin', '');
            end
            if nargin > 1
                values.(name) = newValue;
            end
            value = values.(name);
        end

        function text = stampFor(s)
            text = jsonencode(struct('SpinnakerNet', fileStamp(s.SpinnakerNet), ...
                'SpinVideoNet', fileStamp(s.SpinVideoNet)));
        end

        function text = readStamp()
            text = '';
            p = spincam.internal.NativeEngine.stampPath();
            if isfile(p)
                text = strtrim(fileread(p));
            end
        end

        function errorNoSpinnaker()
            [~, problems] = spincam.internal.NativeEngine.spinnaker();
            detail = '';
            if ~isempty(problems)
                detail = [' ' strjoin(problems, ' ')];
            end
            error('spincam:engine:noSpinnaker', ['Spinnaker .NET assemblies (SpinnakerNET_v*.dll) not found.%s ' ...
                'Install Spinnaker, or run spincam.setup(''SpinnakerDir'', ''<Spinnaker folder>'').'], detail);
        end
    end
end

function st = fileStamp(path)
st = struct('Path', '', 'Bytes', 0, 'Modified', '');
if isempty(path) || ~isfile(path)
    return
end
d = dir(path);
st = struct('Path', path, 'Bytes', d.bytes, ...
    'Modified', char(datetime(d.datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd HH:mm:ss')));
end
