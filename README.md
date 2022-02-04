This repo provides code for interfacing with the CBU MRI Scanner (3T Siemens
Prisma) over a National Instruments card. For further documentation of the CBU
setup, see the [imaging
wiki](http://imaging.mrc-cbu.cam.ac.uk/mri/CbuStimulusDelivery).

# Matlab
For new projects, we recommend using [scansync.m](scansync.m). Documentation
is included in the function, and also reprinted below: 

```matlab
function [resptime,respnumber,daqret] = scansync(ind,waituntil,opt)
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
% STOPPING:
% It is advised to add this line at the end of your script
% It will clear the task and release the device
% scansync('stop');
%
% INPUTS:
% ind: array specifying which channel indices to check (in 1:9 range).
%   Default [], which means that the function waits for the below duration
%   while logging all responses. If a response occurs on any indexed
%   channel the function returns immediately.
% waituntil: optional timestamp to wait until before returning. Default 0,
%   which means check once and return. NB raw time stamps, so to wait 2s,
%   enter GetSecs+2.
% opt: additional options. Currently only 'waitrelease', to wait for any
%   buttons to be released before continuing
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
%
% EXAMPLES:
% % Initialise a scansync session
% tr = 2; % TR in s
% scansync('reset',tr);
%
% % Wait for the first volume trigger (e.g. at start of run), and return
% % the time stamp when that happened.
% start_time = scansync(1,Inf);
%
% % Wait for 4s OR return early if the index-finger button on the right is
% % pressed (button_time will be NaN if there is no press)
% button_time = scansync(2,GetSecs+4); % absolute time stamps
%
% % Wait for the next volume trigger, return its time stamp and estimated number
% [triggertime, triggernum] = scansync(1,Inf);
%
% % Wait 2s no matter what (but keep track of all responses)
% [~, ~, daqstate] = scansync([],GetSecs+2);
%
% % Time stamp for last scanner pulse, which may have occurred during % the 2s interval
% in the example above.
% lastpulse_time = daqstate.lastresp(1);
%
% % Wait for buttons to be released before continuing
%   scansync(2,Inf,'waitrelease'); % will wait infinit time until channel 2
%   button is released
%   scansync_tmp(2,GetSecs+10,'waitrelease'); % will wait for 10s until button
%   is released. If not released will move on anyway.
%
% 2017-04-13 J Carlin, MRC CBU.
% 2019-06-19 Added support for two-handed mode
% 2019-10-02 Documentation, respnumber is scalar return
% 2020-09-21 Switch to undocumented NI API for performance
%
% Dace Apsvalka edits
% 2021-11-10 A new button press is counted only if the button goes from OFF to
%            ON (before it depended on predefined pulse duration)
% 2021-11-10 - Added an option to wait for buttons to be released.
% 2021-12-02 - Added scansync('stop') option to release the device. 
```
We also include a
legacy solution ([ScannerSynchClass.m](ScannerSynchClass.m), [documentation
here](http://imaging.mrc-cbu.cam.ac.uk/mri/ScannerSynch)).


# Others
For python, see [this repo](https://github.com/MRC-CBU/python_scansync).

# Unsolicited advice on coding cognitive experiments
1. Load all your materials into memory before starting the task. Better yet, put them in off-sceen buffers on the GPU.
2. Time your events in absolute, not relative terms (eg, start your trial at time_start + trial_dur * (trial_ind-1)). Allow 'catch-up' phases for inevitable Matlab lag (e.g., 50ms at the end of each trial where you just wait for the start time of the next trial).
3. If you don't have a good reason to be using self-timed elements (e.g., trial advances when subject responds), don't. It introduces all kinds of fun confounds in your design, e.g., dependencies between the visual input and your participant's behaviour (e.g., they'll see more of the stimulus if they respond slowly, and hey presto, your visual cortex codes task difficulty), more tightly clustered trials on 'easy' tasks (and hence lower design efficiency for many contrasts of interest). And it makes your run durations unpredictable.
4. For the love of God, include a fixation cross and tell your participant to look at it. Verify with eye tracker if possible. Just because you don't care about vision and eye movements doesn't mean that these things can't introduce confounds in your data. Without fixation control you have no hope of coming up with sensible covariates for visual input after the fact.
5. Many short runs works much better than a few long ones.
6. If at all possible, score data online and provide participant with feedback at the end of the run. This is motivating and helps participants remember that you are interested in their responses and that their performance matters to you.
