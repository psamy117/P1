%% BATCH ANNEALING FURNACE - HEAT TRANSFER MODEL (FULL CYCLE: HEAT + SOAK + COOL)
%
%  Bell-type batch annealing furnace, coil-on-coil (base + convector plates),
%  combustion-heated inner cover ("muffle") fired on MIXED FUEL GAS, with a
%  fan-circulated HYDROGEN atmosphere used purely as the convective heat
%  transfer medium between the cover and the coil stack (classic HICON/H2
%  type batch annealing furnace).
%
%  Physics modelled:
%   1) Cover (muffle) energy balance: heated by mixed-gas combustion,
%      loses heat by convection to the circulating H2 atmosphere and by
%      radiation directly to the coil stack (through the convector-plate
%      gaps), and loses heat to ambient through the furnace shell.
%   2) H2 atmosphere node: assumed thermally "thin" (small gas mass, fast
%      fan circulation) -> solved as a quasi-steady energy balance between
%      what it picks up from the cover and what it gives up to the coils.
%   3) Each of the N_COILS stacked coils: 1-D transient radial conduction
%      (cylindrical coordinates) from the coil ID (insulated core / eye)
%      out to its own OD, which sees convection from the H2 atmosphere and
%      radiation from the cover. Radial conduction uses an EFFECTIVE radial
%      conductivity that accounts for the stack of wrap-to-wrap air gaps in
%      a coil of wound strip - this is what makes strip THICKNESS matter
%      for the heating rate (thinner strip = more interfaces per metre of
%      radius = lower effective conductivity = slower core heating).
%   4) THREE-STAGE cycle: HEAT (burner drives cover to setpoint until the
%      slowest coil's core reaches ITS OWN target) -> SOAK (hold at
%      temperature for a fixed dwell) -> COOL (burner off, stack cools
%      through the same convective/radiative paths).
%
%  EACH of the 5 stacked coils gets its OWN thickness, width and annealing
%  target - prompted interactively below, coil-by-coil from the furnace
%  base upward. Furnace height is fixed at 7 m and the stack holds 5 coils,
%  per the given furnace design.
%
%  All other quantities are engineering-typical defaults for a mixed-gas
%  fired / H2-convection batch annealing furnace and are clearly marked
%  "ADVANCED PARAMETERS" - edit them if you have plant-specific data.
%
%  Requires: base MATLAB only (ode15s) - no toolboxes.
%
%  Figures are saved to a "furnace_results" folder next to this script
%  (PNG + editable FIG) and the script pauses at the end waiting for
%  Enter - this way results survive even if you launch it in a way that
%  auto-exits MATLAB right after the script finishes (e.g.
%  matlab -r "run('batch_annealing_furnace_model.m'); exit").

clear; clc; close all;

%% =====================================================================
%  1) FURNACE / STACK GEOMETRY (fixed by problem statement)
%  =====================================================================
furnace_height_m = 7.0;     % total inner furnace (base to cover) height
n_coils          = 5;       % coils stacked base-to-top

%% =====================================================================
%  2) USER INPUTS - each of the 5 coils gets its own thickness/width/target
%  =====================================================================
default_thk_mm = [0.30 0.50 0.70 1.00 1.20];   % illustrative per-coil defaults
default_wid_mm = [1000 1100 1200 1000  900];
default_tgt_C  = [680  700  700  720  690];

thickness_mm = zeros(1,n_coils);
width_mm     = zeros(1,n_coils);
T_anneal_C   = zeros(1,n_coils);

for c = 1:n_coils
    fprintf('\n-- Coil %d of %d (stack position, base -> top) --\n', c, n_coils);
    v = input(sprintf('  Strip thickness [mm] (default %.2f): ', default_thk_mm(c)));
    if isempty(v), v = default_thk_mm(c); end
    thickness_mm(c) = v;

    v = input(sprintf('  Coil width [mm] (default %.0f): ', default_wid_mm(c)));
    if isempty(v), v = default_wid_mm(c); end
    width_mm(c) = v;

    v = input(sprintf('  Annealing (soak) temperature [C] (default %.0f): ', default_tgt_C(c)));
    if isempty(v), v = default_tgt_C(c); end
    T_anneal_C(c) = v;
end

fprintf('\n--- Inputs summary ---\n');
fprintf(' Coil | Thickness[mm] | Width[mm] | Target[C]\n');
for c = 1:n_coils
    fprintf('  %2d  |     %5.2f     |   %5.0f   |   %5.0f\n', ...
        c, thickness_mm(c), width_mm(c), T_anneal_C(c));
end
fprintf('\n');

thickness_m = thickness_mm/1000;
width_m     = width_mm/1000;

%% =====================================================================
%  3) ADVANCED PARAMETERS - edit if you have plant-specific data
%  =====================================================================

% --- Coil geometry / material ---------------------------------------
coil_ID_m      = 0.850;     % coil eye (inner bore) diameter, same for all coils
coil_mass_kg   = 20000;     % steel mass per coil (typical ~20 t coil)
rho_steel      = 7850;      % kg/m^3
cp_steel       = 490;       % J/kg/K
k_steel        = 45;        % W/m/K (solid steel conductivity)
R_contact      = 2.2e-4;    % m^2.K/W, wrap-to-wrap contact resistance
                             % (typical range 1e-4 - 5e-4; tighter wound /
                             %  higher tension coils sit lower in this range)
eps_coil       = 0.55;      % coil (steel strip) surface emissivity

% Effective radial conductivity of each WOUND coil (series-resistance model):
%   1/k_eff = 1/k_steel + R_contact/thickness
% -> thinner strip means more wrap interfaces per metre of radius, so
%    k_eff drops (slower radial heat penetration to the core).
k_eff = 1./(1/k_steel + R_contact./thickness_m);       % 1 x n_coils

% Coil OD back-calculated per coil from fixed mass, common ID and own width:
r_ID = coil_ID_m/2;
OD_m = sqrt(coil_ID_m^2 + 4*coil_mass_kg./(pi*rho_steel*width_m));   % 1 x n_coils

fprintf('Derived per-coil geometry:\n');
fprintf(' Coil |  OD[m] | k_eff[W/m/K]\n');
for c = 1:n_coils
    fprintf('  %2d  | %5.3f  |    %5.3f\n', c, OD_m(c), k_eff(c));
end
fprintf('\n');

% --- Furnace shell / cover -------------------------------------------
gap_annulus_m  = 0.30;                  % radial gas gap, largest coil OD to shell
D_shell_m      = max(OD_m) + 2*gap_annulus_m;
A_shell_lat    = pi*D_shell_m*furnace_height_m;      % shell lateral area
M_cover_kg     = 6000;                  % inner cover (muffle) steel mass
Cp_cover       = 500;                   % J/kg/K
A_cover        = pi/4*D_shell_m^2*2 + A_shell_lat*0.3; % approx cover heat
                                         % exchange area (top/bottom + part
                                         % of the muffle side wall)
eps_cover      = 0.80;                  % oxidised muffle steel emissivity
U_loss         = 3.0;                   % W/m^2/K, shell wall loss coeff
T_amb_C        = 25;

% Effective cover-to-coil radiative emissivity (parallel-plate network)
eps_eff = 1/(1/eps_cover + 1/eps_coil - 1);
sigma_SB = 5.670374e-8;

% --- Combustion (mixed gas) -------------------------------------------
LHV_mixedgas_kJ_Nm3 = 5000;   % typical COG/BFG mixed gas calorific value
eta_comb            = 0.85;   % combustion + heat-transfer-to-cover efficiency
Q_burner_max_kW     = 2200;   % total installed burner firing capacity
Kp_cover            = 40;     % kW/K, proportional controller gain
cover_margin_C      = 60;     % HEAT-UP cover setpoint = hottest coil's target
                               % + this margin (standard batch-anneal
                               %  practice: run the cover hot to drive heat
                               %  into the coils quickly)
soak_margin_C       = 15;     % SOAK cover setpoint margin - much smaller,
                               % just enough to offset losses and hold
                               % coils steady at temperature (not still
                               %  ramping them up further)
tol_C               = 5;      % "at temperature" tolerance, deg C

% --- H2 atmosphere / convection ---------------------------------------
% Heat transfer coefficient is modelled as JET IMPINGEMENT through the
% perforated convector plates that sit between the coils (this is how
% HICON/H2-type furnaces actually drive gas onto the coil faces - not
% simple duct flow). Impingement jets reach realistic h ~ 80-150 W/m^2/K
% at H2's low density even at modest total fan flow, because the
% characteristic length (nozzle diameter) is small.
Q_fan_m3s      = 3.0;         % total circulation fan flow, actual m^3/s at
                               % furnace operating temperature (split evenly
                               % across the n_coils convector plate zones)
d_nozzle_m     = 0.03;        % convector plate nozzle/hole diameter
open_area_frac = 0.04;        % nozzle open area as fraction of coil face area
P_furnace_Pa   = 1.05*101325; % slight positive pressure (keeps air out)
M_H2           = 2.016e-3;    % kg/mol
Rg             = 8.314;       % J/mol/K
cp_H2          = 14300;       % J/kg/K (~constant over anneal temp range)

% Simple stack-position factor: hearth/burner-side coils tend to run a
% touch hotter than the top (closer to the cold lid / seal) in a real
% furnace even with convector plates - included only for realism in the
% plotted spread, not a first-order effect.
position_factor = linspace(1.05, 0.95, n_coils);

% --- Radial FD discretisation ------------------------------------------
Nr = 20;   % radial nodes per coil

% --- Cycle timing -------------------------------------------------------
heat_search_hr = 150;   % safety cap: stop the heat-up search if not all
                        % coils reach target by this time (should not be hit)
soak_time_hr   = 6;     % hold time once the slowest coil reaches target
cool_time_hr   = 20;    % simulated cooling duration after soak

%% =====================================================================
%  4) CHECK STACK HEIGHT FITS THE 7 m FURNACE
%  =====================================================================
base_stand_m   = 0.5;    % hearth/base stand height
plate_gap_m    = 0.08;   % convector plate thickness+clearance between coils
top_clear_m    = 0.8;    % clearance under cover for gas circulation/burner
stack_height_m = base_stand_m + sum(width_m) + (n_coils-1)*plate_gap_m + top_clear_m;

fprintf('Stack height required for %d coils (widths as entered): %.2f m (furnace = %.1f m)\n', ...
    n_coils, stack_height_m, furnace_height_m);
if stack_height_m > furnace_height_m
    warning(['Requested coil widths leave the %d-coil stack %.2f m TALLER than the ' ...
        '7 m furnace. Reduce widths.'], n_coils, stack_height_m-furnace_height_m);
else
    fprintf('OK - stack fits with %.2f m clearance.\n\n', furnace_height_m-stack_height_m);
end

%% =====================================================================
%  5) BUILD PER-COIL RADIAL CONDUCTION MATRICES
%  (worked per unit axial length - the radial ODE for a uniform coil does
%   not depend on width, since both capacitance and conduction area scale
%   linearly with it and the ratio cancels. Width only matters for the
%   OD-via-mass relation above and for the total heat-exchange AREA used
%   in the shared cover/gas energy balances further below.)
%  =====================================================================
A_coil3    = zeros(Nr,Nr,n_coils);
flux_ratio = zeros(1,n_coils);     % A_outer_face/C_surf per unit length, per coil
r_cen_all  = zeros(n_coils,Nr);    % radial node centres per coil, for plotting

for c = 1:n_coils
    r_OD = OD_m(c)/2;
    r_edges = linspace(r_ID, r_OD, Nr+1);
    r_cen   = 0.5*(r_edges(1:end-1) + r_edges(2:end));
    r_cen_all(c,:) = r_cen;

    vol_pul  = pi*(r_edges(2:end).^2 - r_edges(1:end-1).^2);   % m^2 (per unit length)
    C_th_pul = rho_steel*cp_steel*vol_pul;                     % J/K per metre

    A_face_pul = 2*pi*r_edges(2:end-1);      % internal interface "areas" per unit length
    dr_cen     = diff(r_cen);
    G_pul      = k_eff(c)*A_face_pul./dr_cen;

    Ac = zeros(Nr,Nr);
    Ac(1,1) = -G_pul(1)/C_th_pul(1);
    Ac(1,2) =  G_pul(1)/C_th_pul(1);
    for i = 2:Nr-1
        Ac(i,i-1) =  G_pul(i-1)/C_th_pul(i);
        Ac(i,i)   = -(G_pul(i-1)+G_pul(i))/C_th_pul(i);
        Ac(i,i+1) =  G_pul(i)/C_th_pul(i);
    end
    Ac(Nr,Nr-1) =  G_pul(Nr-1)/C_th_pul(Nr);
    Ac(Nr,Nr)   = -G_pul(Nr-1)/C_th_pul(Nr);
    A_coil3(:,:,c) = Ac;

    A_outer_pul   = 2*pi*r_edges(end);
    flux_ratio(c) = A_outer_pul/C_th_pul(Nr);
end

%% =====================================================================
%  6) PARAMETER STRUCT + INITIAL CONDITIONS
%  =====================================================================
T0_C = T_amb_C;
y0 = [T0_C; repmat(T0_C, Nr*n_coils, 1)];

params = struct('Nr',Nr,'n_coils',n_coils,'A_coil3',A_coil3,'flux_ratio',flux_ratio, ...
    'position_factor',position_factor, ...
    'A_cover',A_cover,'M_cover_kg',M_cover_kg,'Cp_cover',Cp_cover, ...
    'U_loss',U_loss,'A_shell_lat',A_shell_lat,'T_amb_C',T_amb_C, ...
    'eta_comb',eta_comb,'Q_burner_max_kW',Q_burner_max_kW,'Kp_cover',Kp_cover, ...
    'T_cover_set_C',max(T_anneal_C)+cover_margin_C, ...
    'T_cover_soak_C',max(T_anneal_C)+soak_margin_C, ...
    'eps_eff',eps_eff,'sigma_SB',sigma_SB, ...
    'OD_m',OD_m,'ID_m',coil_ID_m,'width_m',width_m, ...
    'Q_fan_m3s',Q_fan_m3s,'P_furnace_Pa',P_furnace_Pa, ...
    'd_nozzle_m',d_nozzle_m,'open_area_frac',open_area_frac, ...
    'M_H2',M_H2,'Rg',Rg,'cp_H2',cp_H2, ...
    'T_anneal_C',T_anneal_C,'tol_C',tol_C,'phase','heat');

opts_heat = odeset('RelTol',1e-6,'AbsTol',1e-4, ...
    'Events', @(t,y) all_reached_event(t,y,params));

%% =====================================================================
%  7) STAGE A - HEAT UP (until slowest coil reaches ITS OWN target)
%  =====================================================================
t_span_A = linspace(0, heat_search_hr*3600, 600);
[tA, YA, teA] = ode15s(@(t,y) furnace_odes(t,y,params), t_span_A, y0, opts_heat);
if isempty(teA)
    warning('Not all coils reached target within the %.0f h search horizon - check inputs/parameters.', heat_search_hr);
end

%% =====================================================================
%  8) STAGE B - SOAK (hold at temperature for soak_time_hr)
%  =====================================================================
params_soak = params;
params_soak.phase = 'soak';   % lower setpoint - hold steady, don't keep ramping
t_span_B = linspace(0, soak_time_hr*3600, 150);
opts_soak = odeset('RelTol',1e-6,'AbsTol',1e-4);
[tB, YB] = ode15s(@(t,y) furnace_odes(t,y,params_soak), t_span_B, YA(end,:)', opts_soak);

%% =====================================================================
%  9) STAGE C - COOL (burner off)
%  =====================================================================
params_cool = params;
params_cool.phase = 'cool';
t_span_C = linspace(0, cool_time_hr*3600, 300);
opts_cool = odeset('RelTol',1e-6,'AbsTol',1e-4);
[tC, YC] = ode15s(@(t,y) furnace_odes(t,y,params_cool), t_span_C, YB(end,:)', opts_cool);

%% =====================================================================
%  10) STITCH THE THREE STAGES INTO ONE FULL-CYCLE TIME HISTORY
%  =====================================================================
t_heat_end = tA(end);
t_soak_end = t_heat_end + tB(end);
t_total    = t_soak_end + tC(end);

t = [tA; t_heat_end + tB(2:end); t_soak_end + tC(2:end)];
Y = [YA; YB(2:end,:); YC(2:end,:)];
t_hr = t/3600;

T_cover = Y(:,1);
coils   = reshape(Y(:,2:end), length(t), Nr, n_coils);
T_core  = squeeze(coils(:,1,:));     % innermost node (nearest coil eye)
T_surf  = squeeze(coils(:,Nr,:));    % outermost node (coil OD)

% Recover gas temperature and burner firing-rate history (both are algebraic
% functions of the state, not separate ODE states)
T_gas = zeros(size(t));
Q_fuel_kW = zeros(size(t));
for k = 1:length(t)
    if t(k) <= t_heat_end
        phase_k = 'heat';
    elseif t(k) <= t_soak_end
        phase_k = 'soak';
    else
        phase_k = 'cool';
    end
    pk = params; pk.phase = phase_k;
    [~, T_gas(k)] = gas_temp_and_h(T_cover(k), T_surf(k,:), pk);
    switch phase_k
        case 'cool'
            Q_fuel_kW(k) = 0;
        case 'soak'
            Q_fuel_kW(k) = min(max(pk.Kp_cover*(pk.T_cover_soak_C - T_cover(k)), 0), pk.Q_burner_max_kW);
        otherwise
            Q_fuel_kW(k) = min(max(pk.Kp_cover*(pk.T_cover_set_C - T_cover(k)), 0), pk.Q_burner_max_kW);
    end
end
mixedgas_flow_Nm3h = Q_fuel_kW*3600/LHV_mixedgas_kJ_Nm3;      % Nm^3/h
mixedgas_total_Nm3 = trapz(t, mixedgas_flow_Nm3h/3600);        % Nm^3 over full cycle

%% =====================================================================
%  11) RESULTS SUMMARY
%  =====================================================================
fprintf('\n--- Results ---\n');
for c = 1:n_coils
    idx = find(T_core(:,c) >= T_anneal_C(c) - tol_C, 1, 'first');
    if isempty(idx)
        fprintf('Coil %d: core did NOT reach its %.0f C target within the simulated cycle\n', c, T_anneal_C(c));
    else
        fprintf('Coil %d: core reaches its %.0f C target at t = %.1f h (surface was %.0f C)\n', ...
            c, T_anneal_C(c), t_hr(idx), T_surf(idx,c));
    end
end
fprintf('\nHeat-up complete : %.1f h\n', t_heat_end/3600);
fprintf('Soak ends        : %.1f h\n', t_soak_end/3600);
fprintf('Total cycle time : %.1f h (heat %.1f h + soak %.1f h + cool %.1f h)\n', ...
    t_total/3600, t_heat_end/3600, soak_time_hr, cool_time_hr);
fprintf('Mixed fuel gas consumed over full cycle: %.0f Nm^3 (peak firing %.0f kW)\n', ...
    mixedgas_total_Nm3, max(Q_fuel_kW));

%% =====================================================================
%  12) FULL-CYCLE GRAPH (heat + soak + cool, one figure, shared time axis)
%  =====================================================================
fig1 = figure('Name','Full Annealing Cycle','Color','w','Position',[100 100 900 900]);

ax1 = subplot(4,1,1);
plot(t_hr, T_cover, 'r-', 'LineWidth', 1.8); hold on;
plot(t_hr, T_gas, 'b-', 'LineWidth', 1.5);
ylabel('Temp [C]');
legend('Cover (muffle)','H_2 atmosphere','Location','SouthEast');
title('Full Annealing Cycle: Heat-up -> Soak -> Cool'); grid on;

ax2 = subplot(4,1,2);
plot(t_hr, T_core, 'LineWidth', 1.5); hold on;
for c = 1:n_coils
    plot(xlim, [T_anneal_C(c) T_anneal_C(c)], '--', 'Color', [0.5 0.5 0.5], 'HandleVisibility','off');
end
ylabel('Core temp [C]');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), 'Location','SouthEast');
title('Coil CORE Temperature (innermost radial node)'); grid on;

ax3 = subplot(4,1,3);
plot(t_hr, T_surf, 'LineWidth', 1.5);
ylabel('Surface temp [C]');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), 'Location','SouthEast');
title('Coil SURFACE Temperature (outermost radial node)'); grid on;

ax4 = subplot(4,1,4);
plot(t_hr, Q_fuel_kW, 'm-', 'LineWidth', 1.8);
xlabel('Time [h]'); ylabel('Firing rate [kW]');
title('Mixed Fuel Gas Firing Rate'); grid on;

for axh = [ax1 ax2 ax3 ax4]
    yl = get(axh,'YLim');
    hold(axh,'on');
    plot(axh, [t_heat_end t_heat_end]/3600, yl, 'k:', 'HandleVisibility','off');
    plot(axh, [t_soak_end t_soak_end]/3600, yl, 'k:', 'HandleVisibility','off');
    set(axh,'YLim',yl);
end
linkaxes([ax1 ax2 ax3 ax4],'x');

%% =====================================================================
%  13) SUPPLEMENTARY: RADIAL TEMPERATURE PROFILE, ALL COILS, END OF SOAK
%  =====================================================================
fig2 = figure('Name','Radial Temperature Profile (end of soak)','Color','w');
[~, k_soak] = min(abs(t_hr - t_soak_end/3600));
hold on;
for c = 1:n_coils
    plot((r_cen_all(c,:)-r_ID)*1000, squeeze(coils(k_soak,:,c)), 'LineWidth',1.5, ...
        'DisplayName', sprintf('Coil %d (%.2f mm)', c, thickness_mm(c)));
end
xlabel('Radial distance from coil ID [mm]'); ylabel('Temperature [C]');
title('Radial Temperature Profile at End of Soak - all 5 coils');
legend('Location','SouthEast'); grid on;

%% =====================================================================
%  14) SAVE FIGURES TO DISK (results survive even if the MATLAB session
%      is closed/exited automatically right after this script finishes -
%      e.g. when run as `matlab -r "run('this_script.m'); exit"`)
%  =====================================================================
drawnow;
outdir = fullfile(pwd, 'furnace_results');
if ~exist(outdir, 'dir'), mkdir(outdir); end
saveas(fig1, fullfile(outdir, 'full_annealing_cycle.png'));
saveas(fig2, fullfile(outdir, 'radial_temperature_profile.png'));
saveas(fig1, fullfile(outdir, 'full_annealing_cycle.fig'));
saveas(fig2, fullfile(outdir, 'radial_temperature_profile.fig'));
fprintf('\nFigures saved to: %s\n', outdir);

% Keep the figures on screen: if this script is being run non-interactively
% (e.g. `matlab -r "run(...); exit"`), MATLAB would otherwise exit and close
% every figure the instant this script returns. This pause blocks that.
input('\nPress Enter in this window to close... (figures are already saved to disk above)', 's');

%% =====================================================================
%  LOCAL FUNCTIONS
%  =====================================================================
function dydt = furnace_odes(~, y, p)
    Nr = p.Nr; nC = p.n_coils;
    T_cover = y(1);
    coils = reshape(y(2:end), Nr, nC);
    Tsurf = coils(Nr,:);

    [h_conv, T_gas, h_rad] = gas_temp_and_h(T_cover, Tsurf, p);

    % --- Cover (muffle) energy balance ---
    switch p.phase
        case 'cool'
            Q_fuel_kW = 0;
        case 'soak'
            Q_fuel_kW = min(max(p.Kp_cover*(p.T_cover_soak_C - T_cover), 0), p.Q_burner_max_kW);
        otherwise % 'heat'
            Q_fuel_kW = min(max(p.Kp_cover*(p.T_cover_set_C - T_cover), 0), p.Q_burner_max_kW);
    end
    Q_in_W = p.eta_comb * Q_fuel_kW * 1000;

    A_lat = pi*p.OD_m.*p.width_m;  % per-coil OD lateral area
    h_cov_gas = h_cover_gas_coeff(p);
    Q_cov_to_gas = h_cov_gas*p.A_cover*(T_cover - T_gas);

    Q_cov_to_coils_rad = sum(h_rad .* A_lat .* (T_cover - Tsurf));
    Q_loss = p.U_loss*p.A_shell_lat*(T_cover - p.T_amb_C);

    dTcover_dt = (Q_in_W - Q_cov_to_gas - Q_cov_to_coils_rad - Q_loss) / (p.M_cover_kg*p.Cp_cover);

    % --- Each coil's radial conduction + OD boundary flux ---
    dcoils_dt = zeros(Nr, nC);
    for c = 1:nC
        flux_OD = h_conv(c)*(T_gas - Tsurf(c)) + h_rad(c)*(T_cover - Tsurf(c)); % W/m^2
        dTc = p.A_coil3(:,:,c) * coils(:,c);
        dTc(Nr) = dTc(Nr) + flux_OD*p.flux_ratio(c);
        dcoils_dt(:,c) = dTc;
    end

    dydt = [dTcover_dt; dcoils_dt(:)];
end

function [value, isterminal, direction] = all_reached_event(~, y, p)
    Nr = p.Nr; nC = p.n_coils;
    coils = reshape(y(2:end), Nr, nC);
    T_core = coils(1,:);
    value = max(p.T_anneal_C - p.tol_C - T_core);  % >0 until slowest coil catches up
    isterminal = 1;
    direction = -1;
end

function [h_conv, T_gas, h_rad] = gas_temp_and_h(T_cover, Tsurf, p)
    % Quasi-steady H2 atmosphere node + convective/radiative coefficients.
    nC = p.n_coils;
    A_lat = pi*p.OD_m.*p.width_m;

    % --- H2 properties at a first estimate of mean gas temperature ---
    T_guess_K = mean([T_cover; Tsurf(:)]) + 273.15;
    [rho_g, mu_g, k_g] = h2_properties(T_guess_K, p.P_furnace_Pa, p.M_H2, p.Rg);
    Pr = mu_g*p.cp_H2/k_g;

    % Jet impingement through the perforated convector plates: fan flow is
    % split evenly across the n_coils plate zones and forced through small
    % nozzles onto each coil face, giving a high local velocity (and hence
    % realistic h) even though the overall fan flow is modest. Each coil
    % has its own face area (from its own OD), so h_base varies per coil.
    Q_per_coil = p.Q_fan_m3s / nC;
    h_base = zeros(1,nC);
    for c = 1:nC
        A_face   = pi/4*(p.OD_m(c)^2 - p.ID_m^2);
        A_nozzle = p.open_area_frac * A_face;
        v_jet    = Q_per_coil / A_nozzle;
        Re       = rho_g*v_jet*p.d_nozzle_m/mu_g;
        Nu       = 0.285*Re^0.6*Pr^(1/3);       % avg. jet-array impingement
        h_base(c)= Nu*k_g/p.d_nozzle_m;
    end
    h_conv = h_base .* p.position_factor;       % per-coil convective coeff

    h_cov_gas = h_cover_gas_coeff(p);

    % Linearised radiation coefficient, cover <-> each coil surface
    Tc_K = T_cover + 273.15;
    Ts_K = Tsurf + 273.15;
    h_rad = p.eps_eff*p.sigma_SB.*(Tc_K^2 + Ts_K.^2).*(Tc_K + Ts_K) .* p.position_factor;

    numer = h_cov_gas*p.A_cover*T_cover + sum(h_conv.*A_lat.*Tsurf);
    denom = h_cov_gas*p.A_cover + sum(h_conv.*A_lat);
    T_gas = numer/denom;
end

function h = h_cover_gas_coeff(~)
    % Convective coefficient, cover inner face to circulating H2 (fan driven,
    % well-mixed enclosure) - engineering-typical value for H2 atmosphere.
    h = 35; % W/m^2/K
end

function [rho_g, mu_g, k_g] = h2_properties(T_K, P_Pa, M, Rg)
    % Approximate H2 gas properties, valid ~300-1300 K, ideal gas.
    rho_g = P_Pa*M/(Rg*T_K);
    mu_g  = 8.9e-6 * (T_K/300)^0.68;   % Pa.s
    k_g   = 0.182 * (T_K/300)^0.79;    % W/m/K
end
