%FCW  Figure Control Widget: Manipulate figures with key and button presses
%
%   fcw([fig], [buttons], [modifiers])
%   fcw(..., '-link')
%   fcw(..., '-block')
%
% Allows the user to rotate, pan and zoom an axes using key presses and
% mouse gestures. Additionally, press q to quit the widget, r to reset the
% axes and escape to close the figure. This function is non-blocking, but
% fixes axes aspect ratios.
%
% This function plays nicely with other figure callbacks, if called after
% other callbacks have been created. Only figure interactions not used by
% fcw() are passed to previously existing callbacks.
%
% IN:
%   fig - Handle of the figure to be manipulated (default: gcf).
%   buttons - 4x1 cell array indicating the function to associate with
%             each mouse button (left to right) and the scroll action.
%             Functions can be any of:
%                'rot' - Rotate about x and y axes of viewer's coordinate
%                        frame
%                'rotz' - Rotate about z axis of viewer's coordinate frame
%                'zoom' - Zoom (change canera view angle)
%                'zoomz' - Move along z axis of viewer's coordinate frame
%                'pan' - Pan
%                '' - Don't use that button
%             Default: {'rot', 'zoomz', 'pan', 'zoomz'}).
%   modifiers - 1x3 numeric vector indicating which of the modifier keys
%               (shift, ctrl, alt respectively) should be pressed (1), not
%               pressed (0), or can be either (other value), for fcw to
%               react to the button press. E.g. [0 1 NaN] indicates that
%               fcw should react to the button press if and only if shift
%               is not pressed and ctrl is pressed; alt is ignored.
%               Default: [NaN NaN NaN] (i.e. react to all button presses).
%   '-link' - Specify each axis in the figure to maintain the same pose
%   '-block' - The function doesn't return control to the caller until the
%              widget is quit (by pressing 'q') or the function is closed.
%              This can be useful if collecting data in another callback,
%              to be returned by the calling function.
% (C) Copyright Oliver Woodford 2006-2015
% The initial code came from Torsten Vogel's view3d function, which was in
% turn inspired by rotate3d from The MathWorks, Inc.
% Thanks to Sam Johnson for some bug fixes and good feature requests.
function fcwDS(varargin)
% Parse input arguments
addpath(genpath('..\Extras\opcodemesh\opcodemesh'))
addpath(genpath('..\Extras\geodesic_matlab-master\matlab'))
assert(nargin < 6, 'Too many input arguments');
% buttons = {'rot', 'zoomz', 'pan', 'zoom'};
buttons = {'rot', 'zoomz', 'pan', 'zoom'};
fig = gcf();
link = false;
block = false;
modifiers = NaN(1, 3);
trist = struct;
trist.clicked = 0;
trist.phandle = {NaN};
trist.lhandle = {NaN,NaN};
trist.lendpts = [NaN,NaN; NaN,NaN];
trist.bndflag = true;
trist.drawmid = false;
trist.resume = false;
trist.paths = {}; % store paths in format [x,y,z,index]
trist.ismid = []; % for each path, mark if it belongs to the middle
trist.timevals = [];
% set(fig,'UserData',struct('clicked',0,'phandle',{fig}));
%fig.UserData = trist; % klicked triangles, patch handles
for a = 1:nargin
    v = varargin{a};
    if ischar(v) && numel(v) > 1 && v(1) == '-'
        switch v
            case '-link'
                link = true;
            case '-block'
                block = true;
            otherwise
                error('Unknown option: %s.', v);
        end
    elseif isscalar(v) && ishandle(v)
        fig = ancestor(v, 'figure');
        assert(~isempty(fig), 'Unrecognized handle');
    elseif iscell(v) && numel(v) == 4 && all(cellfun(@ischar, v))
        buttons = v;
    elseif isnumeric(v) && numel(v) == 3
        modifiers = v(:)';
    elseif isnumeric(v) && size(v,2)==3 && isequal(v,round(v))
        F = v;
    elseif isnumeric(v) && size(v,2)==3 && ~isequal(v,round(v))
        V = v;
    else
        error('Input not recognized');
    end
end

%% prepare geodesic path computation
% global geodesic_library;                
% geodesic_library = 'geodesic_release';
mesh = geodesic_new_mesh(V,F);         %initilize new mesh
alg = geodesic_new_algorithm(mesh, 'exact');      %initialize new geodesic algorithm

%%

% Flush any pending draws
drawnow;
% Clear any visualization modes we might be in
pan(fig, 'off');
zoom(fig, 'off');
rotate3d(fig, 'off');
% Find all the axes
hAx = findobj(fig, 'Type', 'axes', '-depth', 1);
% For each set of axes
for h = hAx'
    % Set everything to manual
    set(h, 'CameraViewAngleMode', 'manual', 'CameraTargetMode', 'manual', 'CameraPositionMode', 'manual');
    % Store the camera viewpoint
    set(h, 'UserData', camview(h));
end
% Link if necessary
if link
    link = linkprop(hAx, {'CameraPosition', 'CameraTarget', 'CameraViewAngle', 'CameraUpVector', 'Projection'});
end
% TR = triangulation(F,V);
A = adjacency_edge_cost_matrix(V,F);
% A = adjacency_matrix(TR.edges());
G = graph(A);
% Get existing callbacks, and quit a previous instance of fcw if running
[prev_mousedown, prev_mouseup, prev_keypress, prev_scroll] = quit_widget(fig);
% Create the modifier checking function
M = modifiers == 0 | modifiers == 1;
if ~any(M)
    modifiers = @() false;
else
    modifiers = modifiers(M);
    mods = {'shift', 'control', 'alt'};
    mods = mods(M);
    modifiers = @() ~isequal(ismember(mods, get(fig, 'CurrentModifier')), modifiers);
end
% Initialize the callbacks
set(fig, 'WindowButtonDownFcn', [{@fcw_mousedown, {str2func(['fcw_' buttons{1}]), str2func(['fcw_' buttons{2}]), str2func(['fcw_' buttons{3}])}, modifiers} prev_mousedown], ...
         'WindowButtonUpFcn', [{@fcw_mouseup,V,F,G,alg} prev_mouseup], ...
         'KeyPressFcn', [{@fcw_keypress} prev_keypress], ... 
         'WindowScrollWheelFcn', [{@fcw_scroll, str2func(['fcw_' buttons{4}]), modifiers} prev_scroll], ...
         'BusyAction', 'cancel', 'UserData', trist);
if block
    % Block until the figure is closed or the widget is quit
    while 1
        try
            pause(0.01);
            if isempty(get(fig, 'UserData'))
                break;
            end
        catch
            % Figure was closed
            geodesic_delete;
            break;
        end
    end
end
end
function fcw_keypress(src, eventData, varargin)
fig = ancestor(src, 'figure');
cax = get(fig, 'CurrentAxes');
if isempty(cax)
    % Call the other keypress callbacks
    if ~isempty(varargin)
        varargin{1}(src, eventData, varargin{2:end});
    end
    return;
end
step = 1;
if ismember('shift', eventData.Modifier)
    step = 2;
end
if ismember('control', eventData.Modifier)
    step = step * 4;
end
% Which keys do what
switch eventData.Key
    case {'v', 'leftarrow'}
        fcw_pan([], [step 0], cax);
    case {'g', 'rightarrow'}
        fcw_pan([], [-step 0], cax);
    case {'downarrow'}
        fcw_pan([], [0 step], cax);
    case {'h', 'uparrow'}
        fcw_pan([], [0 -step], cax);
    case 'x'
        fcw_rotz([], [0 step], cax);
    case {'j'}
        fcw_rotz([], [0 -step], cax);
    case {'c', 'z'}
        fcw_zoom([], [0 -step], cax);
    case {'k', 'a'}
        fcw_zoom([], [0 step], cax);
    case 'r'
        % Reset all the axes
        for h = findobj(fig, 'Type', 'axes', '-depth', 1)'
            camview(h, get(h, 'UserData'));
        end
    case 'q'
        % Quit the widget
        disp('Resuming')
        trist = get(fig,'UserData');
        trist.resume = true; % resume code
        set(fig,'UserData',trist);
        for h = findobj(fig, 'Type', 'axes', '-depth', 1)'
            camview(h, get(h, 'UserData'));
        end
        quit_widget(fig);
        uiresume;
    case 'escape'
        close(fig);
    case 'n'
        % start drawing a new geodesic
        fig = flush_geo(fig);
        % val = -inf;    
% while abs(val) > 1
%     val = input('Specify the time value between -1 and 1.');
% end
        
    case 'b'
        disp('Switched to boundary mode.')
        trist = get(fig,'UserData');
        trist.bndflag = true; % mark boundaries; use shortest path later
        set(fig,'UserData',trist);
    case 's'
        disp('Switched to seam mode.')
        trist = get(fig,'UserData');
        trist.bndflag = false; % mark seam; use exact geodesics
        set(fig,'UserData',trist);
    case 'm'
        trist = get(fig,'UserData');
        drawmid = trist.drawmid;
        drawmid = ~drawmid;
        if drawmid
            sprintf('Now drawing middle line.')
        else
            sprintf('Now drawing other line.')
        end     
        trist.drawmid = drawmid;
        set(fig,'UserData',trist);
    otherwise
        % Call the other keypress callbacks
        if ~isempty(varargin)
            varargin{1}(src, eventData, varargin{2:end});
        end
end
end
function fcw_mousedown(src, eventData, funcs, modifiers, varargin)
% Check an axes is selected
fig = ancestor(src, 'figure');
cax = get(fig, 'CurrentAxes');
if isempty(cax) || modifiers() % Check the required modifiers were pressed, else do nothing
    % Call the other mousedown callbacks
    % This allows other interactions to be used easily alongside fcw()
    if ~isempty(varargin)
        varargin{1}(src, eventData, varargin{2:end});
    end
    return;
end
% Get the button pressed
switch get(fig, 'SelectionType')
    case 'extend' % Middle button
        method = funcs{2};
    case 'alt' % Right hand button
        method = funcs{3};
    case 'open' % Double click
%         camview(cax, get(cax, 'UserData'));
        return;
    otherwise
        method = funcs{1};
end
% Set the cursor
switch func2str(method)
    case {'fcw_zoom', 'fcw_zoomz', 'fcw_scroll'}
        shape=[ 2   2   2   2   2   2   2   2   2   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   1   1   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   2   2   2   2   2   2   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   2 NaN NaN NaN   2   2   2   2  ;
                2   1   2   1   1   2   1   1   1   2 NaN   2   1   2   1   2  ;
                2   1   2   1   2 NaN   2   1   1   1   2   1   1   2   1   2  ;
                2   2   2   2 NaN NaN NaN   2   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   2   2   2   2   2   2   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   1   1   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   2   2   2   2   2   2   2   2   2  ];
    case 'fcw_pan'
        shape=[ NaN NaN NaN NaN NaN NaN NaN   2   2 NaN NaN NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN NaN   2   1   1   2 NaN NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN   2   1   1   1   1   2 NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN   1   1   1   1   1   1 NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN NaN   2   1   1   2 NaN NaN NaN NaN NaN NaN ;
                NaN NaN   2   1 NaN NaN   2   1   1   2 NaN NaN   1   2 NaN NaN ;
                NaN   2   1   1   2   2   2   1   1   2   2   2   1   1   2 NaN ;
                2   1   1   1   1   1   1   1   1   1   1   1   1   1   1   2 ;
                2   1   1   1   1   1   1   1   1   1   1   1   1   1   1   2 ;
                NaN   2   1   1   2   2   2   1   1   2   2   2   1   1   2 NaN ;
                NaN NaN   2   1 NaN NaN   2   1   1   2 NaN NaN   1   2 NaN NaN ;
                NaN NaN NaN NaN NaN NaN   2   1   1   2 NaN NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN   1   1   1   1   1   1 NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN   2   1   1   1   1   2 NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN NaN   2   1   1   2 NaN NaN NaN NaN NaN NaN ;
                NaN NaN NaN NaN NaN NaN NaN   2   2 NaN NaN NaN NaN NaN NaN NaN ];
    case {'fcw_rotz', 'fcw_rot'}
        % Rotate
        shape=[ NaN NaN NaN   2   2   2   2   2 NaN   2   2 NaN NaN NaN NaN NaN ;
                NaN NaN NaN   1   1   1   1   1   2   1   1   2 NaN NaN NaN NaN ;
                NaN NaN NaN   2   1   1   1   1   2   1   1   1   2 NaN NaN NaN ;
                NaN NaN   2   1   1   1   1   1   2   2   1   1   1   2 NaN NaN ;
                NaN   2   1   1   1   2   1   1   2 NaN NaN   2   1   1   2 NaN ;
                NaN   2   1   1   2 NaN   2   1   2 NaN NaN   2   1   1   2 NaN ;
                2   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   2 ;
                2   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   2 ;
                2   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   2 ;
                2   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   2 ;
                NaN   2   1   1   2 NaN NaN   2   1   2 NaN   2   1   1   2 NaN ;
                NaN   2   1   1   2 NaN NaN   2   1   1   2   1   1   1   2 NaN ;
                NaN NaN   2   1   1   1   2   2   1   1   1   1   1   2 NaN NaN ;
                NaN NaN NaN   2   1   1   1   2   1   1   1   1   2 NaN NaN NaN ;
                NaN NaN NaN NaN   2   1   1   2   1   1   1   1   1 NaN NaN NaN ;
                NaN NaN NaN NaN NaN   2   2 NaN   2   2   2   2   2 NaN NaN NaN ];
    otherwise
        return
end
% Record where the pointer is
global FCW_POS
FCW_POS = get(0, 'PointerLocation');
% Set the cursor and callback
set(ancestor(src, 'figure'), 'Pointer', 'custom', 'pointershapecdata', shape, 'WindowButtonMotionFcn', {method, cax});
end
function fcw_mouseup(src, eventData,V,F,G,alg)
% Clear the cursor and callback
fig = ancestor(src, 'figure');
trist = get(fig,'UserData');
clicked = trist.clicked;
phcell = trist.phandle;
lhcell = trist.lhandle;
lendpts = trist.lendpts;
point = get(gca, 'CurrentPoint'); % mouse click position
tree = opcodemesh(V',F');
[hit,d,trix,bary,Q] = tree.intersect(point(1,:)',diff(point)');
if strcmpi(get(fig, 'selectiontype'),'normal')
    disp('within normal')    
    if ~hit
        disp('No intersection detected.')
    else
        XYZ = [V(F(trix,1),:); V(F(trix,2),:); V(F(trix,3),:)];
        ds = pdist2(Q',XYZ);
        [~,I] = min(ds);
        pid = F(trix,I);
        Vi = V(pid,:);
        cl = find(clicked==pid);
        if ismember(pid, int32(clicked))
            sprintf('Point already clicked! Deleting marker.')
            ph = phcell{cl};
            delete(ph)
            if length(lhcell) > 2
                % delete both lines attached to the deleted point
                % draw a new line between the appropriate other points
                if ismember(2,cl) && clicked(end) == clicked(2) % closed curve
                    lh1 = lhcell{3};
                    lh2 = lhcell{end};
                    delete(lh1); 
                    delete(lh2);
                    lhcell(3) = [];
                    lhcell(end) = [];
                elseif cl == 2 % first point
                    lh = lhcell{cl+1};
                    delete(lh); 
                    lhcell(cl+1) = [];            
                elseif cl == length(clicked) % last point
                    lh = lhcell{cl};
                    delete(lh); 
                    lhcell(cl) = [];
                else % in between
                    lh1 = lhcell{cl};
                    lh2 = lhcell{cl+1};
                    delete(lh1); 
                    delete(lh2);
                    lhcell(cl+1) = [];
                    lh3 = draw_geo(fig,trist.bndflag,G,V,clicked(cl-1),clicked(cl+1),alg);
                    lhcell(cl) = {lh3}; % draw a new line
                end              
            end
            phcell(cl) = [];
            %patch(XYZ(:,1),XYZ(:,2),XYZ(:,3),'r')
            clicked(cl) = [];
            
        else
%             sprintf('Distance = %f',d)
            %sprintf('Triangle index = %d',trix)
%             sprintf('Point index = %d',pid)
            %scatter3(Q(1),Q(2),Q(3),'mo','filled')
            ph = scatter3(Vi(1),Vi(2),Vi(3),'mo','filled');
            %ph = patch(XYZ(:,1),XYZ(:,2),XYZ(:,3),'g');
            phcell = cat(2,phcell,{ph});
            clicked = cat(2,clicked,pid);
            if length(clicked)>2
                lh = draw_geo(fig,trist.bndflag,G,V,clicked(end-1),clicked(end),alg);
                lhcell = cat(2,lhcell,{lh});
                lendpts = cat(1,lendpts,[clicked(end-1),clicked(end)]);
            end
        end
        sprintf(strcat(['clicked = ',num2str(clicked)]))
        disp(lhcell)
    end
    trist.clicked = clicked;
    trist.phandle = phcell;
    trist.lhandle = lhcell;
    trist.lendpts = lendpts;
    set(fig,'UserData',trist);
    %fig.UserData = trist;

elseif strcmpi(get(fig, 'selectiontype'),'open')    
    if length(clicked)>4 && hit
        disp('Double click. Closing and finishing curve.')    
        ph = phcell{end};
        lh = lhcell{end};
        delete(lh); 
        lhcell(end) = [];
        delete(ph)
        clicked(end) = [];
        phcell(end) = [];
        lh = draw_geo(fig,trist.bndflag,G,V,clicked(end),clicked(2),alg);
        lhcell = cat(2,lhcell,{lh});
        lendpts = cat(1,lendpts,[clicked(end),clicked(2)]);
        trist.clicked = clicked;
        trist.phandle = phcell;
        trist.lhandle = lhcell;
        trist.lendpts = lendpts;
        set(fig,'UserData',trist);
        fig = flush_geo(fig);
    end
else
    disp('something else')
end
    %%%
set(ancestor(src, 'figure'), 'WindowButtonMotionFcn', [], 'Pointer', 'arrow');
end
function fcw_scroll(src, eventData, func, modifiers, varargin)
% Get the axes handle

fig = ancestor(src, 'figure');
cax = get(fig, 'CurrentAxes');
if isempty(cax) || modifiers() % Check the required modifiers were pressed, else do nothing
    % Call the other mousedown callbacks
    % This allows other interactions to be used easily alongside fcw()
    if ~isempty(varargin)
        varargin{1}(src, eventData, varargin{2:end});
    end
    return;
end
% Call the scroll function
shape=[ 2   2   2   2   2   2   2   2   2   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   1   1   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   2   2   2   2   2   2   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   2 NaN NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   2 NaN NaN NaN NaN NaN NaN NaN NaN  ;
                2   1   2   1   1   1   1   1   2 NaN NaN NaN   2   2   2   2  ;
                2   1   2   1   1   2   1   1   1   2 NaN   2   1   2   1   2  ;
                2   1   2   1   2 NaN   2   1   1   1   2   1   1   2   1   2  ;
                2   2   2   2 NaN NaN NaN   2   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN NaN NaN   2   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   1   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   2   2   2   2   2   2   2   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   1   1   1   1   1   1   1   1   2  ;
                NaN NaN NaN NaN NaN NaN   2   2   2   2   2   2   2   2   2   2  ];



func([], [0 -10*eventData.VerticalScrollCount], cax);
set(ancestor(src, 'figure'), 'Pointer', 'custom', 'pointershapecdata', shape,'WindowButtonMotionFcn', []);
pause(0.2)
set(ancestor(src, 'figure'), 'WindowButtonMotionFcn', [], 'Pointer', 'arrow');
end
function d = check_vals(s, d)
% Check the inputs to the manipulation methods are valid
global FCW_POS
if ~isempty(s)
    % Return the mouse pointers displacement
    new_pt = get(0, 'PointerLocation');
    d = FCW_POS - new_pt;
    FCW_POS = new_pt;
end
end
% Figure manipulation functions
function fcw_rot(s, d, cax)
d = check_vals(s, d);
try
    % Rotate XY
    camorbit(cax, d(1), d(2), 'camera', [0 0 1]);
catch
    % Error, so release mouse down
    fcw_mouseup(cax)
end
end
function fcw_rotz(s, d, cax)
d = check_vals(s, d);
try
    % Rotate Z
    camroll(cax, d(2));
catch
    % Error, so release mouse down
    fcw_mouseup(cax)
end
end
function fcw_zoom(s, d, cax)
d = check_vals(s, d);
% Zoom
d = (1 - 0.01 * sign(d(2))) ^ abs(d(2));
try
    camzoom(cax, d);
catch
    % Error, so release mouse down
    fcw_mouseup(cax)
end
end
function fcw_zoomz(s, d, cax)
d = check_vals(s, d);
% Zoom by moving towards the camera
d = (1 - 0.01 * sign(d(2))) ^ abs(d(2)) - 1;
try
    camdolly(cax, 0, 0, d, 'fixtarget', 'camera');
catch
    % Error, so release mouse down
    fcw_mouseup(cax)
end
end
function fcw_pan(s, d, cax)
d = check_vals(s, d);
try
    % Pan
    camdolly(cax, d(1), d(2), 0, 'movetarget', 'pixels');
catch
    % Error, so release mouse down
    fcw_mouseup(cax)
end
end
function A = to_cell(A)
if ~iscell(A)
    if isempty(A)
        A = {};
    else
        A = {A};
    end
end
A = reshape(A, 1, []);
end
function [prev_mousedown, prev_mouseup, prev_keypress, prev_scroll] = quit_widget(fig)
% Get the current callbacks
%fig = flush_geo(fig);
usr = fig.UserData;
prev_mousedown = to_cell(get(fig, 'WindowButtonDownFcn'));
prev_mouseup = to_cell(get(fig, 'WindowButtonUpFcn'));
prev_keypress = to_cell(get(fig, 'KeyPressFcn'));
prev_scroll = to_cell(get(fig, 'WindowScrollWheelFcn'));
% Remove the fcw callbacks (assuming they're first)
if ~isempty(prev_mousedown) && strcmp('fcw_mousedown', func2str(prev_mousedown{1}))
    prev_mousedown = prev_mousedown(4:end);
end
if ~isempty(prev_mouseup) && strcmp('fcw_mouseup', func2str(prev_mouseup{1}))
%     prev_mouseup = prev_mouseup(2:end);
    prev_mouseup = prev_mouseup(6:end);
end
if ~isempty(prev_keypress) && strcmp('fcw_keypress', func2str(prev_keypress{1}))
    prev_keypress = prev_keypress(2:end);
end
if ~isempty(prev_scroll) && strcmp('fcw_scroll', func2str(prev_scroll{1}))
    prev_scroll = prev_scroll(4:end);
end
% Reset the callbacks
reset(fig)
set(fig,'UserData',usr);
% set(fig, 'WindowButtonDownFcn', prev_mousedown, 'WindowButtonUpFcn', prev_mouseup, 'KeyPressFcn', prev_keypress, 'WindowScrollWheelFcn', prev_scroll, 'WindowButtonMotionFcn', [], 'Pointer', 'arrow', 'UserData', []);
end