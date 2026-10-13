% Run this script in MATLAB with the supplied files in the same folder.
% Compile and simulate the first 100 seconds; original model is not edited.
folder=fileparts(mfilename('fullpath'));
addpath(folder,'-begin');
clear RCAM_dynamics_fcn20260918 RCAM_monitor
model='RCAM_PID_takeoff_rotation_trial';
load_system(fullfile(folder,[model '.slx']));
plant=[model '/Nonlinear 6DOF RCAM Aircraft Plant Model'];
alt=[model '/Alltitude control'];
% Explicitly configure the new path using Simulink APIs, rather than
% relying on defaults when newly added blocks are loaded from the SLX.
rotationBlock=[alt '/Rotation at 84 mps - 8 deg trial'];
limiterBlock=[alt '/Pitch command slew 2 deg per sec'];
switches=find_system(alt,'SearchDepth',1,'BlockType','MultiPortSwitch');
assert(isscalar(switches),'Expected one pitch-mode selector.');
selector=switches{1};
set_param(rotationBlock,'Expr','(u>=84)*8*pi/180');
set_param(selector,'DataPortOrder','One-based contiguous');
set_param(limiterBlock,'RisingSlewLimit','2*pi/180', ...
    'FallingSlewLimit','-2*pi/180','SampleTimeMode','continuous');
connectTrialInput(alt,[alt '/V_takeoff'],1,rotationBlock,1);
connectTrialInput(alt,rotationBlock,1,selector,2);
connectTrialInput(alt,selector,1,limiterBlock,1);
connectTrialInput(alt,limiterBlock,1,[alt '/Out1'],1);
assert(strcmp(get_param([plant '/RCAM FUNCTION'],'MATLABFcn'), ...
    'RCAM_dynamics_fcn20260918(u(1:12),u(13:17))'));
set_param(model,'SignalLogging','on','SignalLoggingName','logsout', ...
    'StopTime','100','MaxStep','0.01');
sources={plant,2,'theta_actual';plant,3,'altitude'; ...
    plant,5,'airspeed';alt,1,'theta_command'; ...
    [plant '/RCAM FUNCTION1'],1,'forces'; ...
    [alt '/V_takeoff'],1,'rotation_speed_input'; ...
    rotationBlock,1,'rotation_requested'; ...
    [alt '/Subsystem'],1,'pitch_mode'; ...
    selector,1,'selected_pitch_raw'};
for k=1:size(sources,1)
    ports=get_param(sources{k,1},'PortHandles');
    outputPort=ports.Outport(sources{k,2});
    set_param(outputPort,'DataLogging','on','DataLoggingNameMode','Custom', ...
        'DataLoggingName',sources{k,3});
end
set_param(model,'SimulationCommand','update');
disp('MODEL_COMPILE_OK');
result=sim(model,'ReturnWorkspaceOutputs','on');
save(fullfile(folder,'rotation_trial_results.mat'),'result');
theta=result.logsout.get('theta_actual').Values;
h=result.logsout.get('altitude').Values;
V=result.logsout.get('airspeed').Values;
cmd=result.logsout.get('theta_command').Values;
forces=result.logsout.get('forces').Values;
requested=result.logsout.get('rotation_requested').Values;
selected=result.logsout.get('selected_pitch_raw').Values;
mode=result.logsout.get('pitch_mode').Values;
inputV=result.logsout.get('rotation_speed_input').Values;
fprintf('Rotation input speed range: %.3f to %.3f m/s\n', ...
    min(inputV.Data(:)),max(inputV.Data(:)));
fprintf('Requested / selected / final pitch maxima: %.4f / %.4f / %.4f deg\n', ...
    max(requested.Data(:))*180/pi,max(selected.Data(:))*180/pi, ...
    max(cmd.Data(:))*180/pi);
fprintf('Pitch modes observed: %s\n',mat2str(unique(mode.Data(:)).'));
figure('Name','Rotation command path diagnosis');
subplot(3,1,1); plot(inputV.Time,inputV.Data); ylabel('V input [m/s]'); grid on
subplot(3,1,2); plot(mode.Time,mode.Data); ylabel('Mode'); grid on
subplot(3,1,3); plot(requested.Time,requested.Data*180/pi, ...
    selected.Time,selected.Data*180/pi,cmd.Time,cmd.Data*180/pi);
legend({'Requested','Selected','Final command'}); ylabel('Pitch [deg]');
xlabel('Time [s]'); grid on
figure('Name','RCAM rotation trial');
subplot(4,1,1); plot(h.Time,h.Data); ylabel('h [m]'); grid on
subplot(4,1,2); plot(theta.Time,theta.Data*180/pi, ...
    cmd.Time,cmd.Data*180/pi); ylabel('theta [deg]');
legend({'actual','command'}); grid on
subplot(4,1,3); plot(V.Time,V.Data); ylabel('V [m/s]'); grid on
subplot(4,1,4); plot(forces.Time,forces.Data); ylabel('Force [N]');
legend({'L','W','N ground'}); xlabel('Time [s]'); grid on
rotation=find(theta.Data(:)>=0.5*pi/180,1,'first');
airborne=find(h.Data(:)>=1,1,'first');
if isempty(rotation) || isempty(airborne)
    warning('Rotation or liftoff was not detected; inspect the plots.');
else
    fprintf('Actual pitch >=0.5 deg: %.3f s\n',theta.Time(rotation));
    fprintf('Altitude >=1 m: %.3f s\n',h.Time(airborne));
    assert(theta.Time(rotation)<h.Time(airborne), ...
        'Altitude rose before measurable rotation; further tuning is required.');
    disp('ROTATION_BEFORE_LIFTOFF_OK');
end

function connectTrialInput(system,source,sourceNumber,destination,destNumber)
% Reconnect only the destination branch, preserving other signal branches.
sourcePorts=get_param(source,'PortHandles');
destPorts=get_param(destination,'PortHandles');
destPort=destPorts.Inport(destNumber);
line=get_param(destPort,'Line');
if line~=-1
    oldSource=get_param(line,'SrcPortHandle');
    % A dangling line has SrcPortHandle=-1. Never use it as a port handle.
    if oldSource==-1
        delete_line(line);
    elseif oldSource==sourcePorts.Outport(sourceNumber)
        return; % Correctly connected already; leave the connection intact.
    else
        oldBlock=get_param(oldSource,'Parent');
        oldNumber=get_param(oldSource,'PortNumber');
        delete_line(system, ...
            [get_param(oldBlock,'Name') '/' num2str(oldNumber)], ...
            [get_param(destination,'Name') '/' num2str(destNumber)]);
    end
end
% Refresh handles after changes to the block diagram.
sourcePorts=get_param(source,'PortHandles');
destPorts=get_param(destination,'PortHandles');
add_line(system,sourcePorts.Outport(sourceNumber), ...
    destPorts.Inport(destNumber),'autorouting','on');
end
