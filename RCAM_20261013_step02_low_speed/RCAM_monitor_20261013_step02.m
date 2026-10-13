function y = RCAM_monitor_20261013_step02(z)
% STEP02: use the same dynamics function as the aircraft state integration.
X = z(1:12);
U = z(13:17);
% N_ground, L and W are calculated before the wheel-brake force.
% brake_cmd=0 does not change these three outputs in this function version.
[~,L,W,~,~,N_ground] = RCAM_dynamics_fcn20261013_step02_brake(X,U,0);
y = [L;W;N_ground];
end
