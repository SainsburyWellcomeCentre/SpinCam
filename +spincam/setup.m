function report = setup(opts)
%SETUP Check the spincam environment, locate Spinnaker, build and load the native engine.
%   report = spincam.setup() prints a checklist and returns it as a struct.
%
%   Installation folders
%   * spincam can live in any folder. setup adds that folder to the MATLAB path for this
%     session; spincam.setup('SavePath', true) also saves the path.
%   * Spinnaker is found automatically in its standard locations (Teledyne, FLIR Systems or
%     Point Grey Research under Program Files). For any other folder:
%         spincam.setup('SpinnakerDir', 'D:\Programs\Teledyne\Spinnaker')
%         spincam.setup('BrowseSpinnaker', true)          % choose the folder in a dialog
%     The folder may be the Spinnaker root, its bin64 folder, or the folder that holds
%     SpinnakerNET_v140.dll. It is saved in spincam_config.json (spincam folder) and used
%     from then on. The environment variable SPINCAM_SPINNAKER_BIN overrides it.
%   * Spinnaker versions: any installation with the .NET API (SpinnakerNET_v<toolset>.dll)
%     is accepted, because the engine is compiled against the installed assemblies
%     (rebuilt automatically when they change). SpinVideo (AVI/MP4 writers) is optional.
%     spincam was verified with Spinnaker 4.2.0.83.
%
%   Other options: 'ForceBuild' (rebuild native\bin\SpinCamEngine.dll; use a fresh MATLAB
%   session), 'ListCameras' (default true), 'Quiet'.
arguments
    opts.SpinnakerDir {mustBeTextScalar} = ''
    opts.BrowseSpinnaker (1,1) logical = false
    opts.ForceBuild (1,1) logical = false
    opts.ListCameras (1,1) logical = true
    opts.SavePath (1,1) logical = false
    opts.Quiet (1,1) logical = false
end
E = spincam.internal.NativeEngine;
L = spincam.internal.SpinnakerLocator;
root = E.projectRoot();
report = struct('SpincamVersion', spincam.version(), 'SpincamFolder', root, 'Matlab', version(), ...
    'Windows', ispc, 'DotNet', false, 'SpinnakerBin', '', 'SpinnakerSource', '', 'SpinnakerToolset', '', ...
    'SpinVideo', false, 'Compiler', '', 'EngineBuilt', false, 'EngineVersion', '', 'SpinnakerVersion', '', ...
    'Cameras', struct([]), 'Notes', {{}}, 'Errors', {{}});

    function say(tag, text, varargin)
        if ~opts.Quiet
            fprintf('[%-4s] %s\n', tag, sprintf(text, varargin{:}));
        end
    end

    function fail(text, varargin)
        report.Errors{end + 1} = sprintf(text, varargin{:});
        say('FAIL', text, varargin{:});
    end

    function note(text, varargin)
        report.Notes{end + 1} = sprintf(text, varargin{:});
        say('NOTE', text, varargin{:});
    end

    function folder = browse()
        start = 'C:\Program Files';
        if isfolder(fullfile(start, 'Teledyne'))
            start = fullfile(start, 'Teledyne');
        end
        choice = uigetdir(start, 'Select the Spinnaker installation folder (the one containing bin64)');
        folder = '';
        if ischar(choice)
            folder = choice;
        end
    end

say('OK', 'spincam %s in %s', report.SpincamVersion, root);
onPath = contains([pathsep lower(path) pathsep], [pathsep lower(root) pathsep]);
if ~onPath
    addpath(root);
end
if opts.SavePath
    savepath;
    say('OK', 'MATLAB path saved with %s', root);
elseif ~onPath
    note('Added %s to the MATLAB path for this session (spincam.setup(''SavePath'', true) keeps it).', root);
end
say('OK', 'MATLAB %s', report.Matlab);
if isMATLABReleaseOlderThan('R2023b')
    note('MATLAB R2023b or newer is recommended (developed on R2025b).');
end
if ~ispc
    fail('Windows is required (Spinnaker .NET).');
    return
end
report.DotNet = NET.isNETSupported;
if report.DotNet
    say('OK', '.NET Framework interface available');
else
    fail('.NET Framework interface not available in this MATLAB.');
    return
end

% ------------------------------------------------------------------ Spinnaker
interactive = usejava('desktop') && ~batchStartupOptionUsed;
folder = char(opts.SpinnakerDir);
if opts.BrowseSpinnaker
    folder = browse();
    if isempty(folder)
        fail('No Spinnaker folder selected.');
        return
    end
end
if ~isempty(folder)
    s = L.inspect(folder);
    if isempty(s)
        fail(['No SpinnakerNET_v*.dll found in or below %s. Choose the Spinnaker installation folder ' ...
            '(for example C:\\Program Files\\Teledyne\\Spinnaker).'], folder);
        return
    end
    L.remember(s.Folder);
    s.Source = 'spincam.setup';
    say('OK', 'Saved Spinnaker folder %s in %s', s.Folder, L.configPath());
    env = getenv('SPINCAM_SPINNAKER_BIN');
    if ~isempty(env)
        note('SPINCAM_SPINNAKER_BIN is set (%s) and takes precedence over the saved folder.', env);
    end
else
    [s, problems] = E.spinnaker();
    for k = 1:numel(problems)
        note('%s', problems{k});
    end
    if isempty(s) && interactive
        note('Spinnaker was not found in the standard locations; select its installation folder.');
        folder = browse();
        if ~isempty(folder)
            s = L.inspect(folder);
            if ~isempty(s)
                L.remember(s.Folder);
                s.Source = 'spincam.setup';
            end
        end
    end
    if isempty(s)
        fail(['Spinnaker .NET assemblies (SpinnakerNET_v*.dll) not found. Install the Spinnaker SDK with its ' ...
            '.NET components, then run spincam.setup(''SpinnakerDir'', ''<Spinnaker folder>'').']);
        return
    end
end
report.SpinnakerBin = s.Bin;
report.SpinnakerSource = s.Source;
report.SpinnakerToolset = s.Toolset;
report.SpinVideo = ~isempty(s.SpinVideoNet);
say('OK', 'Spinnaker assemblies: %s (%s, found via %s)', s.Bin, s.Toolset, s.Source);
if ~report.SpinVideo
    note(['SpinVideoNET not found: formats avi-mjpeg, avi-raw and mp4-h264 are unavailable; raw, ' ...
        'matlab-avi and matlab-mjpeg still work.']);
end
if E.isLoaded() && ~strcmpi(E.loadedBin(), s.Bin)
    note('This MATLAB session already loaded Spinnaker from %s; restart MATLAB to use %s.', E.loadedBin(), s.Bin);
end

report.Compiler = E.compilerPath();
if isfile(report.Compiler)
    say('OK', 'C# compiler: %s', report.Compiler);
else
    note('C# compiler not found at %s (only needed to build the engine).', report.Compiler);
end

try
    if opts.ForceBuild || E.isStale()
        E.build(true);
        say('OK', 'Engine built: %s', E.dllPath());
    else
        say('OK', 'Engine up to date: %s', E.dllPath());
    end
    report.EngineBuilt = true;
    E.load();
    report.EngineVersion = E.engineVersion();
    say('OK', 'Engine loaded (version %s, SpinVideo %s)', report.EngineVersion, char(string(E.hasSpinVideo())));
catch me
    fail('%s', me.message);
    return
end

if opts.ListCameras
    try
        sys = spincam.internal.SpinnakerSystem.instance();
        sys.acquire();
        releaser = onCleanup(@() sys.release());
        report.SpinnakerVersion = sys.LibraryVersion;
        report.Cameras = sys.enumerate();
        say('OK', 'Spinnaker %s: %d camera(s)', report.SpinnakerVersion, numel(report.Cameras));
        for k = 1:numel(report.Cameras)
            c = report.Cameras(k);
            say('OK', '  %s  %s  %s  %s', c.Serial, c.Model, c.Firmware, c.Speed);
        end
        if ~strcmp(report.SpinnakerVersion, E.VerifiedSpinnakerVersion)
            note(['spincam was verified with Spinnaker %s; this is %s. The engine is compiled against the ' ...
                'installed version, so it is expected to work: run runTests(''hardware'') once with cameras ' ...
                'attached to confirm.'], E.VerifiedSpinnakerVersion, report.SpinnakerVersion);
        end
        clear releaser
    catch me
        fail('Camera enumeration failed: %s', me.message);
    end
end
end
