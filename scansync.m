function [resptime,respnumber,daqret] = scansync(ind,waituntil)
% synchronise with volume acquisition trigger pulses and record button 
% presses from CBU National Instruments MRI scanner interface.
%
% We support a crude emulation mode (a pretend trigger is sent every tr 
% seconds, pretend buttonbox presses are logged on keyboard keys [v,b,n,m]
% and [f,d,s,a]), which is triggered automatically whenever the NI box
% cannot be detected.
%
% The first time you use this function in a session, you must initialise it
% with a special call syntax as described below. After that the call syntax
% is as in the inputs/outputs section.
%
% INITIALISATION:
% scansync('reset', tr) % where tr is repetition time in seconds
%
% INPUTS:
% ind: array specifying which channel indices to check (in 1:9 range).
%   Default [], which means that the function waits for the below duration
%   while logging all responses. If a response occurs on any indexed
%   channel the function returns immediately.
% waituntil: optional timestamp to wait until before returning. Default 0,
%   which means check once and return. NB raw time stamps, so to wait 2s, 
%   enter GetSecs+2.
%
% OUTPUTS:
% resptime: array of response time for each channel specified in input ind,
%   or NaN if no response was received on that channel. Raw time stamps
%   from psychtoolbox (see GetSecs).
% respnumber: estimated current volume. Note that this is only a time / tr
%   dead reckoning operation. We do not make any attempt to track actual
%   TR.
% daqret: struct with internal state. Mainly useful for debugging and
%   advanced use cases (see example below).
%
% EXAMPLES:
% % initialise a scansync session
% tr = 2; % TR in s
% scansync('reset',tr);
% % wait for the first volume trigger (e.g. at start of run), and return
% % the time stamp when that happened.
% start_time = scansync(1,Inf);
%
% % wait for 4s OR return early if the index-finger button on the right is
% % pressed (button_time will be NaN if there is no press)
% button_time = scansync(2,GetSecs+4); % absolute time stamps
%
% % wait for the next volume trigger, return its time stamp and estimated number
% [triggertime, triggernum] = scansync(1,Inf);
%
% % wait 2s no matter what (but keep track of all responses)
% [~, ~, daqstate] = scansync([],GetSecs+2);
% % time stamp for last recording trigger, which may have occurred during
% % the 2s interval in the example above.
% lastpulse_time = daqstate.lastresp(1);
%
% 2017-04-13 J Carlin, MRC CBU.
% 2019-06-19 Added support for two-handed mode
% 2019-10-02 Documentation, respnumber is scalar return
%
% [resptime,respnumber,daqstate] = scansync(ind,waituntil)

persistent daqstate

% input check
if ~exist('ind','var')
    ind = [];
end
if ~exist('waituntil','var') || isempty(waituntil) || isnan(waituntil)
    waituntil = 0;
end
assert(~isinf(waituntil) || ~isempty(ind), ...
    'unspecified channel index must be combined with finite waituntil duration')

if isstr(ind) && strcmpi(ind,'reset')
    % special case to handle re-initialising sync
    if ~isempty(daqstate)
        daqstate.hand.release();
    end
    daqstate = [];
    ind = [];
end

if isempty(daqstate)
    % special initialisation mode
    tr = waituntil;
    % ordinarily infinite wait durations are fine, but not if you're
    % initialising a new session
    assert(~isinf(tr) && isscalar(tr),'tr must be finite, numeric, scalar');
    % check for DAQ
    hasdaq = false;
    try
        D = daq.getDevices;
        hasdaq = ~isempty(D) && D.isvalid && any(strcmp({D.Vendor.ID},'ni')) && ...
                D.Vendor.isvalid && D.Vendor.IsOperational;
    catch err
        if ~strcmp(err.identifier,'MATLAB:undefinedVarOrClass')
            rethrow(err);
        end
    end
    if hasdaq
        fprintf('initialising new scanner card connection\n');
        warning off daq:Session:onDemandOnlyChannelsAdded
        daqstate.hand = daq.createSession('ni');
        daqstate.tr = tr;
        % Add channels for scanner pulse
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line0', 'InputOnly');
        % Add channels for button 1-4
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line1', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line2', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line3', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line4', 'InputOnly');
        % Add channels for button 5-8
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line5', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line6', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port0/line7', 'InputOnly');
        daqstate.hand.addDigitalChannel('Dev1', 'port1/line0', 'InputOnly');
        daqstate.emulate = false;
        daqstate.nchannel = numel(daqstate.hand.Channels);
    else
        fprintf(['NI CARD NOT AVAILABLE - entering emulation mode with tr=' ...
            mat2str(tr) '\n']);
        fprintf('if you see this message in the scanner, DO NOT PROCEED\n')
        % struct with a function handle in place of inputSingleScan
        daqstate = daqemulator(tr);
    end
    daqstate.firstresp = NaN([1,daqstate.nchannel]);
    daqstate.lastresp = NaN([1,daqstate.nchannel]);
    daqstate.thisresp = NaN([1,daqstate.nchannel]);
    daqstate.nrecorded = zeros(1,daqstate.nchannel);
    % we count pulses if they are >.02s apart, and button presses if they are
    % more than .2s apart
    daqstate.pulsedur = [.006,ones(1,daqstate.nchannel-1)*.2];
end

% always call once (so we get an update even if waituntil==0)
daqstate = checkdaq(daqstate);
while (GetSecs < waituntil) && all(isnan(daqstate.thisresp(ind)))
    daqstate = checkdaq(daqstate);
    % avoid choking the CPU, but don't wait so long that we might miss a pulse
    WaitSecs(min(daqstate.pulsedur)/3);
end

% so now this will be NaN if no responses happened, or otherwise not nan. Note
% that if you entered multiple indices we will return when the FIRST of these is
% true. So resptime will practically always only have a single non-nan entry
% (barring simultaneous key presses), and to the extent that you have multiple
% entries, they'll all show the same time.
resptime = daqstate.thisresp(ind);

% time to estimate the current pulse. only useful for scanner triggers
% (channel 1)
if nargout > 1
    respnumber = floor((GetSecs - daqstate.firstresp(1)) / daqstate.tr);
end

if nargout > 2
    daqret = daqstate;
end

function daqstate = checkdaq(daqstate)
timenow = GetSecs;
% call the DAQ - trigger, buttons 1:9
daqflags = ~daqstate.hand.inputSingleScan();

% wipe whatever we had in thisresp from the last call
daqstate.thisresp = NaN([1,daqstate.nchannel]);

% if any of the responses are new, keep track of when this occurred
newresp = isnan(daqstate.firstresp);
daqstate.firstresp(daqflags & newresp) = timenow;
daqstate.lastresp(daqflags & newresp) = timenow;
daqstate.thisresp(daqflags & newresp) = timenow;

% were any responses sufficiently far past a previous response to count as a
% discrete event?
valid = daqflags & timenow>((daqstate.lastresp+daqstate.pulsedur));
if any(valid)
    % if so, we need to update lastresp and thisresp
    daqstate.lastresp(valid) = timenow;
    daqstate.thisresp(valid) = timenow;
    daqstate.nrecorded(valid) = daqstate.nrecorded(valid)+1;
end

function daqstate = daqemulator(tr)

daqstate.tr = tr;
daqstate.emulate = true;
% fake method
daqstate.hand.inputSingleScan = @emulatecard;
% dummy 
daqstate.hand.release = @(x)fprintf('reset scansync session.\n');
daqstate.emulatekeys = [KbName('v'), KbName('b'), KbName('n'), KbName('m'), ...
    KbName('f'), KbName('d'), KbName('s'), KbName('a')];
daqstate.firstcall = true;
daqstate.nchannel = 9;

function flags = emulatecard()

% pull in the current daqstate
daqstate = evalin('caller','daqstate');

% NB inverted coding on NI cards
flags = true(1,daqstate.nchannel);
if daqstate.firstcall
    % make sure we return nothing the very first time we call (on init). This is
    % hacky but important to avoid starting the pulse emulator too early.
    daqstate.firstcall = false;
    % write it back to the caller
    assignin('caller','daqstate',daqstate);
    return
end

if isnan(daqstate.firstresp(1))
    % record a pulse on first call to start the emulated pulse sequence
    flags(1) = false;
else
    % use the start time to work out whether we should be sending a pulse
    timenow = GetSecs;
    if rem(timenow-daqstate.firstresp(1),daqstate.tr(1))<daqstate.pulsedur(1)
        flags(1) = false;
    end
end

% check for buttons
[keyisdown,~,keyCode] = KbCheck;
if keyisdown
    % flip any keys that match the emulator keys
    respk = find(keyCode);
    [~,ind] = intersect(daqstate.emulatekeys,respk);
    % need to offset by 1 to stay clear of pulse channel
    flags(ind+1) = false;
end
