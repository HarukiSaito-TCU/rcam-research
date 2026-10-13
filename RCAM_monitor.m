function y = RCAM_monitor(z)
X = z(1:12);
U = z(13:17);

[~,L,W,~,~,N_ground] = RCAM_dynamics_fcn20260918(X,U);
y = [L;W;N_ground];
end