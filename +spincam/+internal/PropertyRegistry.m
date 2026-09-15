classdef PropertyRegistry
    %PROPERTYREGISTRY Friendly camera property names and their GenICam plumbing.
    %   Each definition lists candidate node names (first existing wins), the
    %   auto-mode node to switch Off before writing, and feature-enable nodes to
    %   set true before writing. Unknown names are treated as raw GenICam nodes.

    methods (Static)
        function defs = all()
            defs = [ ...
                def('FrameRate', {}, {'AcquisitionFrameRate'}, {'AcquisitionFrameRateAuto'}, ...
                    {'AcquisitionFrameRateEnabled', 'AcquisitionFrameRateEnable'}, 'Hz', false)
                def('ExposureTime', {'Exposure', 'Shutter'}, {'ExposureTime'}, {'ExposureAuto'}, {}, 'us', false)
                def('Gain', {}, {'Gain'}, {'GainAuto'}, {}, 'dB', false)
                def('BlackLevel', {'Brightness'}, {'BlackLevel'}, {'BlackLevelAuto'}, ...
                    {'BlackLevelEnabled', 'BlackLevelEnable'}, '%', false)
                def('Gamma', {}, {'Gamma'}, {}, {'GammaEnabled', 'GammaEnable'}, '', false)
                def('Sharpness', {}, {'Sharpness'}, {'SharpnessAuto'}, {'SharpnessEnabled'}, '', false)
                def('ExposureAuto', {}, {'ExposureAuto'}, {}, {}, '', false)
                def('GainAuto', {}, {'GainAuto'}, {}, {}, '', false)
                def('FrameRateAuto', {}, {'AcquisitionFrameRateAuto'}, {}, {}, '', false)
                def('PixelFormat', {}, {'PixelFormat'}, {}, {}, '', true)
                def('Width', {}, {'Width'}, {}, {}, 'px', true)
                def('Height', {}, {'Height'}, {}, {}, 'px', true)
                def('OffsetX', {}, {'OffsetX'}, {}, {}, 'px', true)
                def('OffsetY', {}, {'OffsetY'}, {}, {}, 'px', true)
                def('ThroughputLimit', {}, {'DeviceLinkThroughputLimit'}, {}, {}, 'B/s', false)
                ];
        end

        function d = lookup(name)
            %LOOKUP Definition for a friendly name or alias ([] for raw node names).
            name = char(name);
            defs = spincam.internal.PropertyRegistry.all();
            d = [];
            for k = 1:numel(defs)
                if strcmpi(defs(k).Name, name) || any(strcmpi(defs(k).Aliases, name))
                    d = defs(k);
                    return
                end
            end
        end

        function names = friendlyNames()
            names = {spincam.internal.PropertyRegistry.all().Name};
        end

        function names = uiNames()
            %UINAMES Properties exposed as controls in the live viewer.
            names = {'FrameRate', 'ExposureTime', 'Gain', 'BlackLevel', 'Gamma'};
        end
    end
end

function d = def(name, aliases, nodes, autoNodes, enableNodes, unit, requiresStopped)
d = struct('Name', name, 'Aliases', {aliases}, 'Nodes', {nodes}, ...
    'AutoNodes', {autoNodes}, 'EnableNodes', {enableNodes}, 'Unit', unit, ...
    'RequiresStopped', requiresStopped);
end
