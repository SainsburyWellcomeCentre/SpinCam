classdef EngineBuildTest < matlab.unittest.TestCase
    %ENGINEBUILDTEST The engine compiles against the installed Spinnaker, with and without SpinVideo.

    properties
        OutDir
    end

    methods (TestClassSetup)
        function requirements(tc)
            E = spincam.internal.NativeEngine;
            tc.assumeTrue(ispc && NET.isNETSupported, 'Requires Windows with .NET.');
            tc.assumeNotEmpty(E.spinnakerBin(), 'Requires Spinnaker assemblies.');
            tc.assumeTrue(isfile(E.compilerPath()), 'Requires the .NET Framework C# compiler.');
        end
    end

    methods (TestMethodSetup)
        function makeOutputFolder(tc)
            tc.OutDir = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
                sprintf('EngineBuildTest_%s_%d', char(datetime('now', 'Format', 'HHmmssSSS')), randi(1e6)));
            mkdir(tc.OutDir);
            tc.addTeardown(@() rmdir(tc.OutDir, 's'));
        end
    end

    methods (Test)
        function compilesWithoutSpinVideo(tc)
            % Spinnaker installations without SpinVideoNET must still get an engine (raw/MATLAB formats).
            E = spincam.internal.NativeEngine;
            out = fullfile(tc.OutDir, 'NoSpinVideo.dll');
            E.compileTo(out, E.spinnaker(), false);
            tc.verifyTrue(isfile(out));
        end

        function loadedEngineMatchesInstallation(tc)
            E = spincam.internal.NativeEngine;
            E.load();
            s = E.spinnaker();
            tc.verifyEqual(E.loadedBin(), s.Bin);
            tc.verifyEqual(E.hasSpinVideo(), ~isempty(s.SpinVideoNet));
            tc.verifyFalse(E.isStale(), 'The build stamp matches the installed Spinnaker assemblies');
            tc.verifyTrue(isfile(E.stampPath()));
        end
    end
end
