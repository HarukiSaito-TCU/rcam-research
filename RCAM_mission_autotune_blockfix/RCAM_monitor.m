function y = RCAM_monitor(z)
[~,L,W,~,~,N_ground] = RCAM_dynamics_fcn20260918(z(1:12),z(13:17));
y = [L;W;N_ground];
end
