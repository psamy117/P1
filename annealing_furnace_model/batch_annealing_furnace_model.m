%% BATCH ANNEALING FURNACE - HEAT TRANSFER MODEL
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
%      out to the coil OD, which sees convection from the H2 atmosphere
%      and radiation from the cover. Radial conduction uses an EFFECTIVE
%      radial conductivity that accounts for the stack of wrap-to-wrap air
%      gaps in a coil of wound strip - this is what makes strip THICKNESS
%      matter for the heating rate (thinner strip = more interfaces per
%      metre of radius = lower effective conductivity = slower core heating).
%
%  USER INPUTS (thickness, width, annealing temperature) are requested
%  interactively below. Furnace height is fixed at 7 m and the stack holds
%  5 coils, per the given furnace design.
%
%  All other quantities are engineering-typical defaults for a mixed-gas
%  fired / H2-convection batch annealing furnace and are clearly marked
%  "ADVANCED PARAMETERS" - edit them if you have plant-specific data.
%
%  Requires: Optimization not needed. Uses ode15s (stiff solver) from base
%  MATLAB - no toolboxes required.

clear; clc; close all;

%% =====================================================================
%  1) USER INPUTS
%  =====================================================================
thickness_mm = input('Strip thickness [mm] (e.g. 0.5): ');
if isempty(thickness_mm), thickness_mm = 0.5; end

width_mm = input('Coil width [mm] (axial length of coil, e.g. 1200): ');
if isempty(width_mm), width_mm = 1200; end

T_anneal_C = input('Annealing (soak) temperature [deg C] (e.g. 700): ');
if isempty(T_anneal_C), T_anneal_C = 700; end

fprintf('\n--- Inputs ---\n');
fprintf('Strip thickness   : %.3f mm\n', thickness_mm);
fprintf('Coil width        : %.1f mm\n', width_mm);
fprintf('Annealing temp    : %.1f C\n\n', T_anneal_C);

%% =====================================================================
%  2) FURNACE / STACK GEOMETRY (fixed by problem statement)
%  =====================================================================
furnace_height_m = 7.0;     % total inner furnace (base to cover) height
n_coils          = 5;       % coils stacked base-to-top

thickness_m = thickness_mm/1000;
width_m     = width_mm/1000;

%% =====================================================================
%  3) ADVANCED PARAMETERS - edit if you have plant-specific data
%  =====================================================================

% --- Coil geometry / material ---------------------------------------
coil_ID_m      = 0.850;     % coil eye (inner bore) diameter -> radius below
coil_mass_kg   = 20000;     % steel mass per coil (typical ~20 t coil)
rho_steel      = 7850;      % kg/m^3
cp_steel       = 490;       % J/kg/K
k_steel        = 45;        % W/m/K (solid steel conductivity)
R_contact      = 2.2e-4;    % m^2.K/W, wrap-to-wrap contact resistance
                             % (typical range 1e-4 - 5e-4; tighter wound /
                             %  higher tension coils sit lower in this range)
eps_coil       = 0.55;      % coil (steel strip) surface emissivity

% Effective radial conductivity of the WOUND coil (series-resistance model):
%   1/k_eff = 1/k_steel + R_contact/thickness
% -> thinner strip means more wrap interfaces per metre of radius, so
%    k_eff drops (slower radial heat penetration to the core).
k_eff = 1/(1/k_steel + R_contact/thickness_m);

% Coil OD back-calculated from fixed mass, ID and (user) width:
r_ID = coil_ID_m/2;
OD_m = sqrt(coil_ID_m^2 + 4*coil_mass_kg/(pi*rho_steel*width_m));
r_OD = OD_m/2;

fprintf('Derived coil geometry: ID = %.3f m, OD = %.3f m, k_eff = %.3f W/m/K\n\n', ...
    coil_ID_m, OD_m, k_eff);

% --- Furnace shell / cover -------------------------------------------
gap_annulus_m  = 0.30;                 % radial gas gap coil-OD to shell
D_shell_m      = OD_m + 2*gap_annulus_m;
A_shell_lat    = pi*D_shell_m*furnace_height_m;      % shell lateral area
M_cover_kg     = 6000;                 % inner cover (muffle) steel mass
Cp_cover       = 500;                  % J/kg/K
A_cover        = pi/4*D_shell_m^2*2 + A_shell_lat*0.3; % approx cover heat
                                        % exchange area (top/bottom + part
                                        % of the muffle side wall)
eps_cover      = 0.80;                 % oxidised muffle steel emissivity
U_loss         = 3.0;                  % W/m^2/K, shell wall loss coeff
T_amb_C        = 25;

% Effective cover-to-coil radiative emissivity (parallel-plate network)
eps_eff = 1/(1/eps_cover + 1/eps_coil - 1);
sigma_SB = 5.670374e-8;

% --- Combustion (mixed gas) -------------------------------------------
LHV_mixedgas_kJ_Nm3 = 5000;   % typical COG/BFG mixed gas calorific value
eta_comb            = 0.85;   % combustion + heat-transfer-to-cover efficiency
Q_burner_max_kW     = 2200;   % total installed burner firing capacity
Kp_cover            = 40;     % kW/K, proportional controller gain
cover_margin_C      = 60;     % cover setpoint = anneal target + margin
                               % (standard batch-anneal practice: run the
                               %  cover hot to drive heat into the coils)

% --- H2 atmosphere / convection ---------------------------------------
% Heat transfer coefficient is modelled as JET IMPINGEMENT through the
% perforated convector plates that sit between the coils (this is how
% HICON/H2-type furnaces actually drive gas onto the coil faces - not
% simple duct flow). Impingement jets reach realistic h ~ 80-150 W/m^2/K
% at H2's low density even at modest total fan flow, because the
% characteristic length (nozzle diameter) is small.
Q_fan_m3s     = 3.0;          % total circulation fan flow, actual m^3/s at
                               % furnace operating temperature (split evenly
                               % across the n_coils convector plate zones)
d_nozzle_m    = 0.03;         % convector plate nozzle/hole diameter
open_area_frac= 0.04;         % nozzle open area as fraction of coil face area
P_furnace_Pa  = 1.05*101325;  % slight positive pressure (keeps air out)
M_H2          = 2.016e-3;     % kg/mol
Rg            = 8.314;        % J/mol/K
cp_H2         = 14300;        % J/kg/K (~constant over anneal temp range)

% Simple stack-position factor: hearth/burner-side coils tend to run a
% touch hotter than the top (closer to the cold lid / seal) in a real
% furnace even with convector plates - included only for realism in the
% plotted spread, not a first-order effect.
position_factor = linspace(1.05, 0.95, n_coils);

% --- Radial FD discretisation ------------------------------------------
Nr = 20;   % radial nodes per coil

% --- Simulation control --------------------------------------------
t_end_hr  = 60;                 % total simulated cycle time [hours]
n_out     = 400;                % number of output/report points

%% =====================================================================
%  4) CHECK STACK HEIGHT FITS THE 7 m FURNACE
%  =====================================================================
base_stand_m   = 0.5;    % hearth/base stand height
plate_gap_m    = 0.08;   % convector plate thickness+clearance between coils
top_clear_m    = 0.8;    % clearance under cover for gas circulation/burner
stack_height_m = base_stand_m + n_coils*width_m + (n_coils-1)*plate_gap_m + top_clear_m;

fprintf('Stack height required for %d coils of %.0f mm width: %.2f m (furnace = %.1f m)\n', ...
    n_coils, width_mm, stack_height_m, furnace_height_m);
if stack_height_m > furnace_height_m
    warning(['Requested coil width leaves the %d-coil stack %.2f m TALLER than the ' ...
        '7 m furnace. Reduce width or coil count.'], n_coils, stack_height_m-furnace_height_m);
else
    fprintf('OK - stack fits with %.2f m clearance.\n\n', furnace_height_m-stack_height_m);
end

%% =====================================================================
%  5) BUILD RADIAL CONDUCTION MATRIX (identical for every coil)
%  =====================================================================
r_edges = linspace(r_ID, r_OD, Nr+1);
r_cen   = 0.5*(r_edges(1:end-1) + r_edges(2:end));

vol   = pi*(r_edges(2:end).^2 - r_edges(1:end-1).^2) * width_m;  % m^3
C_th  = rho_steel*cp_steel*vol;                                  % J/K per node

A_face = 2*pi*r_edges(2:end-1)*width_m;   % internal interface areas (Nr-1 of them)
dr_cen = diff(r_cen);
G      = k_eff*A_face./dr_cen;            % conductance between node i,i+1 [W/K]

A_coil = zeros(Nr,Nr);
A_coil(1,1) = -G(1)/C_th(1);
A_coil(1,2) =  G(1)/C_th(1);
for i = 2:Nr-1
    A_coil(i,i-1) =  G(i-1)/C_th(i);
    A_coil(i,i)   = -(G(i-1)+G(i))/C_th(i);
    A_coil(i,i+1) =  G(i)/C_th(i);
end
A_coil(Nr,Nr-1) =  G(Nr-1)/C_th(Nr);
A_coil(Nr,Nr)   = -G(Nr-1)/C_th(Nr);

A_outer_face = 2*pi*r_edges(end)*width_m;   % coil OD lateral surface area
C_surf       = C_th(Nr);

%% =====================================================================
%  6) INITIAL CONDITIONS AND ODE INTEGRATION
%  =====================================================================
T0_C = T_amb_C;
y0 = [T0_C; repmat(T0_C, Nr*n_coils, 1)];

params = struct('Nr',Nr,'n_coils',n_coils,'A_coil',A_coil, ...
    'A_outer_face',A_outer_face,'C_surf',C_surf,'position_factor',position_factor, ...
    'A_cover',A_cover,'M_cover_kg',M_cover_kg,'Cp_cover',Cp_cover, ...
    'U_loss',U_loss,'A_shell_lat',A_shell_lat,'T_amb_C',T_amb_C, ...
    'eta_comb',eta_comb,'LHV_mixedgas_kJ_Nm3',LHV_mixedgas_kJ_Nm3, ...
    'Q_burner_max_kW',Q_burner_max_kW,'Kp_cover',Kp_cover, ...
    'T_cover_set_C',T_anneal_C+cover_margin_C, ...
    'eps_eff',eps_eff,'sigma_SB',sigma_SB, ...
    'gap_annulus_m',gap_annulus_m,'D_shell_m',D_shell_m,'OD_m',OD_m,'ID_m',coil_ID_m, ...
    'width_m',width_m,'Q_fan_m3s',Q_fan_m3s,'P_furnace_Pa',P_furnace_Pa, ...
    'd_nozzle_m',d_nozzle_m,'open_area_frac',open_area_frac, ...
    'M_H2',M_H2,'Rg',Rg,'cp_H2',cp_H2);

t_span = linspace(0, t_end_hr*3600, n_out);
opts = odeset('RelTol',1e-6,'AbsTol',1e-4);
[t, Y] = ode15s(@(t,y) furnace_odes(t,y,params), t_span, y0, opts);

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
    [~, T_gas(k)] = gas_temp_and_h(T_cover(k), T_surf(k,:), params);
    Q_fuel_kW(k) = min(max(params.Kp_cover*(params.T_cover_set_C - T_cover(k)), 0), params.Q_burner_max_kW);
end
mixedgas_flow_Nm3h = Q_fuel_kW*3600/LHV_mixedgas_kJ_Nm3;      % Nm^3/h
mixedgas_total_Nm3 = trapz(t, mixedgas_flow_Nm3h/3600);        % Nm^3 over full cycle

%% =====================================================================
%  7) RESULTS SUMMARY
%  =====================================================================
tol_C = 5; % consider "at temperature" within 5 C of target
fprintf('\n--- Results ---\n');
for c = 1:n_coils
    idx = find(T_core(:,c) >= T_anneal_C - tol_C, 1, 'first');
    if isempty(idx)
        fprintf('Coil %d (position %d of %d): core did NOT reach target in %.0f h\n', ...
            c, c, n_coils, t_end_hr);
    else
        fprintf('Coil %d (position %d of %d): core reaches %.0f C at t = %.1f h (surface was %.0f C)\n', ...
            c, c, n_coils, T_anneal_C, t_hr(idx), T_surf(idx,c));
    end
end
fprintf('\nEffective radial conductivity k_eff = %.3f W/m/K (vs solid steel %.0f W/m/K)\n', k_eff, k_steel);
fprintf('Coil OD = %.3f m, mass = %.0f kg, width = %.0f mm\n', OD_m, coil_mass_kg, width_mm);
fprintf('Mixed fuel gas consumed over %.0f h cycle: %.0f Nm^3 (peak firing %.0f kW)\n', ...
    t_end_hr, mixedgas_total_Nm3, max(Q_fuel_kW));

%% =====================================================================
%  8) PLOTS
%  =====================================================================
figure('Name','Furnace & Atmosphere Temperatures','Color','w');
plot(t_hr, T_cover, 'r-', 'LineWidth', 1.8); hold on;
plot(t_hr, T_gas, 'b-', 'LineWidth', 1.8);
plot(xlim, [T_anneal_C T_anneal_C], 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
xlabel('Time [h]'); ylabel('Temperature [C]');
legend('Cover (muffle)','H_2 atmosphere','Location','SouthEast');
title('Cover and H_2 Atmosphere Temperature'); grid on;

figure('Name','Mixed Fuel Gas Firing Rate','Color','w');
plot(t_hr, Q_fuel_kW, 'm-', 'LineWidth', 1.8);
xlabel('Time [h]'); ylabel('Burner firing rate [kW]');
title('Mixed Fuel Gas Firing Rate (cover temperature controller)'); grid on;

figure('Name','Coil Core & Surface Temperatures','Color','w');
subplot(2,1,1);
plot(t_hr, T_core, 'LineWidth', 1.5); hold on;
plot(xlim, [T_anneal_C T_anneal_C], 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
xlabel('Time [h]'); ylabel('Core temp [C]');
title('Coil CORE Temperature (innermost radial node) - all 5 stack positions');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), ...
    'Location','SouthEast');
grid on;

subplot(2,1,2);
plot(t_hr, T_surf, 'LineWidth', 1.5); hold on;
plot(xlim, [T_anneal_C T_anneal_C], 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
xlabel('Time [h]'); ylabel('Surface temp [C]');
title('Coil SURFACE Temperature (outermost radial node)');
legend(arrayfun(@(c) sprintf('Coil %d',c), 1:n_coils, 'UniformOutput', false), ...
    'Location','SouthEast');
grid on;

figure('Name','Radial Temperature Profile (Coil 1) at selected times','Color','w');
snap_hr = [1 5 10 20 30 t_hr(end)];
snap_hr = snap_hr(snap_hr <= t_hr(end));
hold on;
for s = snap_hr
    [~, k] = min(abs(t_hr - s));
    plot((r_cen-r_ID)*1000, squeeze(coils(k,:,1)), 'LineWidth',1.5, ...
        'DisplayName', sprintf('t = %.0f h', t_hr(k)));
end
xlabel('Radial distance from coil ID [mm]'); ylabel('Temperature [C]');
title('Radial Temperature Profile, Coil 1 (ID -> OD)');
legend('Location','SouthEast'); grid on;

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
    T_set = p.T_cover_set_C;
    Q_fuel_kW = min(max(p.Kp_cover*(T_set - T_cover), 0), p.Q_burner_max_kW);
    Q_in_W = p.eta_comb * Q_fuel_kW * 1000;

    A_lat = pi*p.OD_m*p.width_m;  % per-coil OD lateral area
    h_cov_gas = h_cover_gas_coeff(p);
    Q_cov_to_gas = h_cov_gas*p.A_cover*(T_cover - T_gas);

    Q_cov_to_coils_rad = sum(h_rad .* A_lat .* (T_cover - Tsurf));
    Q_loss = p.U_loss*p.A_shell_lat*(T_cover - p.T_amb_C);

    dTcover_dt = (Q_in_W - Q_cov_to_gas - Q_cov_to_coils_rad - Q_loss) / (p.M_cover_kg*p.Cp_cover);

    % --- Each coil's radial conduction + OD boundary flux ---
    dcoils_dt = zeros(Nr, nC);
    for c = 1:nC
        flux_OD = h_conv(c)*(T_gas - Tsurf(c)) + h_rad(c)*(T_cover - Tsurf(c)); % W/m^2
        dTc = p.A_coil * coils(:,c);
        dTc(Nr) = dTc(Nr) + flux_OD*p.A_outer_face/p.C_surf;
        dcoils_dt(:,c) = dTc;
    end

    dydt = [dTcover_dt; dcoils_dt(:)];
end

function [h_conv, T_gas, h_rad] = gas_temp_and_h(T_cover, Tsurf, p)
    % Quasi-steady H2 atmosphere node + convective/radiative coefficients.
    nC = p.n_coils;
    A_lat = pi*p.OD_m*p.width_m;

    % --- H2 properties at a first estimate of mean gas temperature ---
    T_guess_K = mean([T_cover; Tsurf(:)]) + 273.15;
    [rho_g, mu_g, k_g] = h2_properties(T_guess_K, p.P_furnace_Pa, p.M_H2, p.Rg);

    % Jet impingement through the perforated convector plates: fan flow is
    % split evenly across the n_coils plate zones and forced through small
    % nozzles onto each coil face, giving a high local velocity (and hence
    % realistic h) even though the overall fan flow is modest.
    A_face   = pi/4*(p.OD_m^2 - p.ID_m^2);          % coil annular face area
    A_nozzle = p.open_area_frac * A_face;           % open nozzle area per zone
    Q_per_coil = p.Q_fan_m3s / nC;
    v_jet = Q_per_coil / A_nozzle;
    Re = rho_g*v_jet*p.d_nozzle_m/mu_g;
    Pr = mu_g*p.cp_H2/k_g;
    Nu = 0.285*Re^0.6*Pr^(1/3);                     % avg. jet-array impingement
    h_base = Nu*k_g/p.d_nozzle_m;
    h_conv = h_base * p.position_factor;            % per-coil convective coeff

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
