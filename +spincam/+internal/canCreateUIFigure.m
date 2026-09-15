function tf = canCreateUIFigure()
%CANCREATEUIFIGURE True when this MATLAB session can create (invisible) uifigures.
%   -batch sessions without a desktop may not support App Designer graphics.
tf = false;
try
    f = uifigure('Visible', 'off');
    delete(f);
    tf = true;
catch
end
end
