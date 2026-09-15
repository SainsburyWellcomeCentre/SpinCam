classdef SpinnakerLocatorTest < matlab.unittest.TestCase
    %SPINNAKERLOCATORTEST Finding Spinnaker assemblies in different install layouts (fake files, no .NET).

    properties
        Root
    end

    methods (TestMethodSetup)
        function makeLayouts(tc)
            tc.Root = fullfile(spincam.internal.NativeEngine.projectRoot(), 'tests', '_output', ...
                sprintf('SpinnakerLocatorTest_%s_%d', char(datetime('now', 'Format', 'HHmmssSSS')), randi(1e6)));
            tc.addTeardown(@() rmdir(tc.Root, 's'));
            % Spinnaker 4.x layout, with debug and GUI assemblies that must be ignored.
            touch(tc.Root, 'Teledyne\Spinnaker\bin64\vs2015', {'SpinnakerNET_v140.dll', 'SpinVideoNET_v140.dll', ...
                'SpinnakerNETd_v140.dll', 'SpinnakerNETGUI_v140.dll', 'SpinVideoNETd_v140.dll'});
            % A hypothetical newer build next to the old toolset.
            touch(tc.Root, 'Newer\Spinnaker\bin64\vs2015', {'SpinnakerNET_v140.dll', 'SpinVideoNET_v140.dll'});
            touch(tc.Root, 'Newer\Spinnaker\bin64\vs2019', {'SpinnakerNET_v142.dll', 'SpinVideoNET_v142.dll'});
            % An installation without SpinVideo.
            touch(tc.Root, 'NoVideo\bin64\vs2015', {'SpinnakerNET_v140.dll'});
            mkdir(fullfile(tc.Root, 'Empty'));
        end
    end

    methods (Test)
        function acceptsRootBin64OrToolsetFolder(tc)
            L = spincam.internal.SpinnakerLocator;
            bin = fullfile(tc.Root, 'Teledyne', 'Spinnaker', 'bin64', 'vs2015');
            for folder = {fullfile(tc.Root, 'Teledyne', 'Spinnaker'), fileparts(bin), bin}
                s = L.inspect(folder{1});
                tc.verifyEqual(s.Bin, bin);
                tc.verifyEqual(s.Toolset, 'v140');
                tc.verifyEqual(s.SpinnakerNet, fullfile(bin, 'SpinnakerNET_v140.dll'));
                tc.verifyEqual(s.SpinVideoNet, fullfile(bin, 'SpinVideoNET_v140.dll'));
            end
        end

        function newestToolsetWins(tc)
            s = spincam.internal.SpinnakerLocator.inspect(fullfile(tc.Root, 'Newer', 'Spinnaker'));
            tc.verifyEqual(s.Toolset, 'v142');
            tc.verifyTrue(endsWith(s.SpinVideoNet, 'SpinVideoNET_v142.dll'));
        end

        function spinVideoIsOptional(tc)
            s = spincam.internal.SpinnakerLocator.inspect(fullfile(tc.Root, 'NoVideo'));
            tc.verifyEqual(s.Toolset, 'v140');
            tc.verifyEmpty(s.SpinVideoNet);
        end

        function nothingFound(tc)
            L = spincam.internal.SpinnakerLocator;
            tc.verifyEmpty(L.inspect(fullfile(tc.Root, 'Empty')));
            tc.verifyEmpty(L.inspect(fullfile(tc.Root, 'DoesNotExist')));
            tc.verifyEmpty(L.inspect(''));
        end

        function acceptsWslPaths(tc)
            folder = fullfile(tc.Root, 'NoVideo');
            wsl = ['/mnt/' lower(folder(1)) strrep(folder(3:end), '\', '/')];
            tc.verifyEqual(spincam.internal.SpinnakerLocator.inspect(wsl).Folder, folder);
        end

        function searchOrderEnvironmentConfigDefaults(tc)
            L = spincam.internal.SpinnakerLocator;
            config = fullfile(tc.Root, 'spincam_config.json');
            defaults = {fullfile(tc.Root, 'Teledyne', 'Spinnaker')};
            [s, problems] = L.find('ConfigPath', config, 'Environment', '', 'DefaultRoots', defaults);
            tc.verifyEqual(s.Source, 'standard location');
            tc.verifyEmpty(problems);

            L.remember(fullfile(tc.Root, 'Newer', 'Spinnaker'), config);
            s = L.find('ConfigPath', config, 'Environment', '', 'DefaultRoots', defaults);
            tc.verifyEqual(s.Source, 'spincam_config.json');
            tc.verifyEqual(s.Toolset, 'v142');

            [s, problems] = L.find('ConfigPath', config, 'Environment', fullfile(tc.Root, 'Empty'), ...
                'DefaultRoots', defaults);
            tc.verifyEqual(s.Source, 'spincam_config.json', 'A bad environment folder falls through');
            tc.verifyNumElements(problems, 1);
            tc.verifySubstring(problems{1}, 'SPINCAM_SPINNAKER_BIN');

            s = L.find('ConfigPath', config, 'Environment', fullfile(tc.Root, 'NoVideo'), 'DefaultRoots', defaults);
            tc.verifyEqual(s.Source, 'SPINCAM_SPINNAKER_BIN');
        end

        function rememberKeepsOtherSettings(tc)
            L = spincam.internal.SpinnakerLocator;
            config = fullfile(tc.Root, 'spincam_config.json');
            fid = fopen(config, 'w');
            fwrite(fid, '{"Other": 5}', 'char');
            fclose(fid);
            L.remember(fullfile(tc.Root, 'NoVideo'), config);
            cfg = L.readConfig(config);
            tc.verifyEqual(cfg.Other, 5);
            tc.verifyEqual(cfg.SpinnakerDir, fullfile(tc.Root, 'NoVideo'));
        end

        function defaultRootsCoverKnownVendors(tc)
            roots = spincam.internal.SpinnakerLocator.defaultRoots();
            tc.verifyTrue(any(endsWith(roots, 'Teledyne\Spinnaker')));
            tc.verifyTrue(any(endsWith(roots, 'FLIR Systems\Spinnaker')));
        end
    end
end

function touch(root, relative, names)
folder = fullfile(root, relative);
mkdir(folder);
for k = 1:numel(names)
    fid = fopen(fullfile(folder, names{k}), 'w');
    fclose(fid);
end
end
