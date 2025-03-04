﻿using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using ControllerCommon;
using ControllerCommon.Controllers;
using ControllerCommon.Inputs;
using ControllerCommon.Managers;
using ControllerCommon.Pipes;
using ControllerCommon.Platforms;
using ControllerCommon.Utils;
using HandheldCompanion.Controllers;
using HandheldCompanion.Controls;
using HandheldCompanion.Views;
using HandheldCompanion.Views.Classes;
using Nefarius.Utilities.DeviceManagement.PnP;
using SharpDX.DirectInput;
using SharpDX.XInput;
using DeviceType = SharpDX.DirectInput.DeviceType;

namespace HandheldCompanion.Managers;

public static class ControllerManager
{
    private static readonly Dictionary<string, IController> Controllers = new();

    private static readonly ConcurrentDictionary<UserIndex, bool> XUsbControllers = new();

    private static readonly XInputController? emptyXInput = new();
    private static readonly DS4Controller? emptyDS4 = new();

    private static IController? targetController;
    private static GamepadWindow? focusedWindow;
    private static ProcessEx? foregroundProcess;
    private static bool ControllerMuted;

    public static bool IsInitialized;

    public static void Start()
    {
        DeviceManager.XUsbDeviceArrived += XUsbDeviceArrived;
        DeviceManager.XUsbDeviceRemoved += XUsbDeviceRemoved;

        DeviceManager.HidDeviceArrived += HidDeviceArrived;
        DeviceManager.HidDeviceRemoved += HidDeviceRemoved;

        DeviceManager.Initialized += DeviceManager_Initialized;

        SettingsManager.SettingValueChanged += SettingsManager_SettingValueChanged;

        GamepadFocusManager.GotFocus += GamepadFocusManager_GotFocus;
        GamepadFocusManager.LostFocus += GamepadFocusManager_LostFocus;

        ProcessManager.ForegroundChanged += ProcessManager_ForegroundChanged;

        PipeClient.Connected += OnClientConnected;

        MainWindow.CurrentDevice.KeyPressed += CurrentDevice_KeyPressed;
        MainWindow.CurrentDevice.KeyReleased += CurrentDevice_KeyReleased;

        // enable HidHide
        HidHide.SetCloaking(true);

        IsInitialized = true;
        Initialized?.Invoke();

        // summon an empty controller, used to feed Layout UI
        // todo: improve me
        ControllerSelected?.Invoke(GetEmulatedController());

        LogManager.LogInformation("{0} has started", "ControllerManager");
    }

    private static void GamepadFocusManager_LostFocus(Control control)
    {
        if (focusedWindow == (GamepadWindow)control)
        {
            focusedWindow = null;

            // check applicable scenarios
            CheckControllerScenario();
        }
    }

    private static void GamepadFocusManager_GotFocus(Control control)
    {
        focusedWindow = (GamepadWindow)control;

        // check applicable scenarios
        CheckControllerScenario();
    }

    private static void ProcessManager_ForegroundChanged(ProcessEx processEx, ProcessEx backgroundEx)
    {
        foregroundProcess = processEx;

        // check applicable scenarios
        CheckControllerScenario();
    }

    private static void CurrentDevice_KeyReleased(ButtonFlags button)
    {
        // calls current controller (if connected)
        var controller = GetTargetController();
        controller?.InjectButton(button, false, true);
    }

    private static void CurrentDevice_KeyPressed(ButtonFlags button)
    {
        // calls current controller (if connected)
        var controller = GetTargetController();
        controller?.InjectButton(button, true, false);
    }

    private static void CheckControllerScenario()
    {
        ControllerMuted = false;

        // controller specific scenarios
        if (targetController?.GetType() == typeof(NeptuneController))
        {
            var neptuneController = (NeptuneController)targetController;

            // mute virtual controller if foreground process is Steam or Steam-related and user a toggle the mute setting
            if (foregroundProcess?.Platform == PlatformType.Steam)
                if (neptuneController.IsVirtualMuted())
                {
                    ControllerMuted = true;
                }
        }

        // either main window or quicktools are focused
        if (focusedWindow is not null)
        {
            ControllerMuted = true;
        }
    }

    public static void Stop()
    {
        if (!IsInitialized)
            return;

        IsInitialized = false;

        DeviceManager.XUsbDeviceArrived -= XUsbDeviceArrived;
        DeviceManager.XUsbDeviceRemoved -= XUsbDeviceRemoved;

        DeviceManager.HidDeviceArrived -= HidDeviceArrived;
        DeviceManager.HidDeviceRemoved -= HidDeviceRemoved;

        SettingsManager.SettingValueChanged -= SettingsManager_SettingValueChanged;

        // uncloak on close, if requested
        if (SettingsManager.GetBoolean("HIDuncloakonclose"))
            foreach (var controller in Controllers.Values)
                controller.Unhide();

        // unplug on close
        var target = GetTargetController();
        target?.Unplug();

        LogManager.LogInformation("{0} has stopped", "ControllerManager");
    }

    private static void SettingsManager_SettingValueChanged(string name, object value)
    {
        // UI thread (async)
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            switch (name)
            {
                case "HIDstrength":
                    var HIDstrength = Convert.ToDouble(value);
                    SetHIDStrength(HIDstrength);
                    break;

                case "SteamDeckMuteController":
                {
                    var target = GetTargetController();
                    if (target is null)
                        return;

                    if (typeof(NeptuneController) != target.GetType())
                        return;

                    var Muted = Convert.ToBoolean(value);
                    ((NeptuneController)target).SetVirtualMuted(Muted);
                }
                    break;

                case "SteamDeckHDRumble":
                {
                    var target = GetTargetController();
                    if (target is null)
                        return;

                    if (typeof(NeptuneController) != target.GetType())
                        return;

                    var HDRumble = Convert.ToBoolean(value);
                    ((NeptuneController)target).SetHDRumble(HDRumble);
                }
                    break;
            }
        });
    }

    private static void DeviceManager_Initialized()
    {
        // search for last known controller and connect
        var path = SettingsManager.GetString("HIDInstancePath");

        if (Controllers.ContainsKey(path))
        {
            // last known controller still is plugged, set as target
            SetTargetController(path);
        }
        else if (HasPhysicalController())
        {
            // no known controller, connect to first available
            path = GetPhysicalControllers().FirstOrDefault().GetContainerInstancePath();
            SetTargetController(path);
        }
    }

    private static void SetHIDStrength(double value)
    {
        GetTargetController()?.SetVibrationStrength(value, SettingsManager.IsInitialized);
    }

    private static void HidDeviceArrived(PnPDetails details, DeviceEventArgs obj)
    {
        if (!details.isGaming)
            return;

        if (Controllers.TryGetValue(details.baseContainerDeviceInstanceId, out IController controller))
        {
            if (!controller.IsPowerCycling)
                return;

            // unset flag
            controller.IsPowerCycling = false;

            // set flag
            details.isHooked = true;

            LogManager.LogDebug("DInput controller power-cycled: {0}", controller.ToString());

            return;
        }

        var directInput = new DirectInput();
        int VendorId = details.attributes.VendorID;
        int ProductId = details.attributes.ProductID;

        // UI thread (synchronous)
        // We need to wait for each controller to initialize and take (or not) its slot in the array
        Application.Current.Dispatcher.Invoke(() =>
        {
            // initialize controller vars
            Joystick joystick = null;
            IController controller = null;

            // search for the plugged controller
            foreach (var deviceInstance in
                     directInput.GetDevices(DeviceType.Gamepad, DeviceEnumerationFlags.AllDevices))
                try
                {
                    // Instantiate the joystick
                    var lookup_joystick = new Joystick(directInput, deviceInstance.InstanceGuid);
                    var SymLink = DeviceManager.PathToInstanceId(lookup_joystick.Properties.InterfacePath,
                        obj.InterfaceGuid.ToString());

                    // IG_ means it is an XInput controller and therefore is handled elsewhere
                    if (lookup_joystick.Properties.InterfacePath.Contains("IG_",
                            StringComparison.InvariantCultureIgnoreCase))
                        continue;

                    if (SymLink.Equals(details.SymLink, StringComparison.InvariantCultureIgnoreCase))
                    {
                        joystick = lookup_joystick;
                        break;
                    }
                }
                catch
                {
                }

            if (joystick is not null)
            {
                // supported controller
                VendorId = joystick.Properties.VendorId;
                ProductId = joystick.Properties.ProductId;
            }
            else
            {
                // unsupported controller
                LogManager.LogError("Couldn't find matching DInput controller: VID:{0} and PID:{1}",
                    details.GetVendorID(), details.GetProductID());
            }

            // search for a supported controller
            switch (VendorId)
            {
                // SONY
                case 0x054C:
                {
                    switch (ProductId)
                    {
                        case 0x0268: // DualShock 3
                        case 0x05C4: // DualShock 4
                        case 0x09CC: // DualShock 4 (2nd Gen)
                        case 0x0CE6: // DualSense
                            controller = new DS4Controller(joystick, details);
                            break;
                    }
                }
                    break;

                // STEAM
                case 0x28DE:
                {
                    switch (ProductId)
                    {
                        // STEAM DECK
                        case 0x1205:
                            controller = new NeptuneController(details);
                            break;
                    }
                }
                    break;

                // NINTENDO
                case 0x057E:
                {
                    switch (ProductId)
                    {
                        // Nintendo Wireless Gamepad
                        case 0x2009:
                            break;
                    }
                }
                    break;
            }

            // unsupported controller
            if (controller is null)
            {
                LogManager.LogError("Unsupported DInput controller: VID:{0} and PID:{1}", details.GetVendorID(),
                    details.GetProductID());
                return;
            }

            // failed to initialize
            if (controller.Details is null)
                return;

            if (!controller.IsConnected())
                return;

            // update or create controller
            var path = controller.GetContainerInstancePath();
            Controllers[path] = controller;

            // first controller logic
            if (!controller.IsVirtual() && GetTargetController() is null && DeviceManager.IsInitialized)
                SetTargetController(controller.GetContainerInstancePath());

            // raise event
            ControllerPlugged?.Invoke(controller);
            LogManager.LogDebug("DInput controller plugged: {0}", controller.ToString());

            ToastManager.SendToast(controller.ToString(), "detected");
        });
    }

    private static void HidDeviceRemoved(PnPDetails details, DeviceEventArgs obj)
    {
        if (!Controllers.TryGetValue(details.baseContainerDeviceInstanceId, out var controller))
            return;

        // XInput controller are handled elsewhere
        if (controller.GetType() == typeof(XInputController))
            return;

        // ignore the event if device is power cycling
        if (controller.IsPowerCycling)
            return;

        // controller was unplugged
        Controllers.Remove(details.baseContainerDeviceInstanceId);

        // unplug controller, if needed
        if (GetTargetController()?.GetContainerInstancePath() == details.baseContainerDeviceInstanceId)
            ClearTargetController();

        // raise event
        ControllerUnplugged?.Invoke(controller);
    }

    private static void XUsbDeviceArrived(PnPDetails details, DeviceEventArgs obj)
    {
        if (Controllers.TryGetValue(details.baseContainerDeviceInstanceId, out IController controller))
        {
            if (!controller.IsPowerCycling)
                return;

            // unset flag
            controller.IsPowerCycling = false;

            // set flag
            details.isHooked = true;

            LogManager.LogDebug("XInput controller power-cycled: {0}", controller.ToString());

            return;
        }

        // trying to guess XInput behavior...
        // get first available slot
        var slot = UserIndex.One;
        Controller _controller = new(slot);

        for (slot = UserIndex.One; slot <= UserIndex.Four; slot++)
        {
            _controller = new Controller(slot);

            // check if controller is connected and slot free
            if (_controller.IsConnected && !XUsbControllers.ContainsKey(slot))
                break;
        }

        LogManager.LogDebug("XInput slot available: {0}", slot);

        // UI thread (synchronous)
        // We need to wait for each controller to initialize and take (or not) its slot in the array
        Application.Current.Dispatcher.Invoke(() =>
        {
            XInputController controller = new(_controller);

            // failed to initialize
            if (controller.Details is null)
                return;

            if (!controller.IsConnected())
                return;

            // slot is now busy
            XUsbControllers[slot] = true;

            // update or create controller
            var path = controller.GetContainerInstancePath();
            Controllers[path] = controller;

            // first controller logic
            if (!controller.IsVirtual() && GetTargetController() is null && DeviceManager.IsInitialized)
                SetTargetController(controller.GetContainerInstancePath());

            // raise event
            ControllerPlugged?.Invoke(controller);
            LogManager.LogDebug("XInput controller plugged: {0}", controller.ToString());

            ToastManager.SendToast(controller.ToString(), "detected");
        });
    }

    private static void XUsbDeviceRemoved(PnPDetails details, DeviceEventArgs obj)
    {
        if (!Controllers.TryGetValue(details.baseContainerDeviceInstanceId, out var controller))
            return;

        // ignore the event if device is power cycling
        if (controller.IsPowerCycling)
            return;

        // slot is now free
        var slot = (UserIndex)controller.GetUserIndex();
        XUsbControllers.Remove(slot, out _);

        // controller was unplugged
        Controllers.Remove(details.baseContainerDeviceInstanceId);

        // unplug controller, if needed
        if (GetTargetController()?.GetContainerInstancePath() == controller.GetContainerInstancePath())
            ClearTargetController();

        // raise event
        ControllerUnplugged?.Invoke(controller);
    }

    private static void ClearTargetController()
    {
        // unplug previous controller
        if (targetController is not null)
        {
            targetController.InputsUpdated -= UpdateInputs;
            targetController.MovementsUpdated -= UpdateMovements;
            targetController.Unplug();
            targetController = null;
        }
    }

    public static void SetTargetController(string baseContainerDeviceInstanceId)
    {
        // unplug previous controller
        ClearTargetController();

        // warn service the current controller has been unplugged
        PipeClient.SendMessage(new PipeClientControllerDisconnect());

        // look for new controller
        if (!Controllers.TryGetValue(baseContainerDeviceInstanceId, out IController? controller))
            return;

        if (controller is null)
            return;

        /*
        if (controller.IsVirtual())
            return;
        */

        // update target controller
        targetController = controller;
        targetController.InputsUpdated += UpdateInputs;
        targetController.MovementsUpdated += UpdateMovements;
        targetController.Plug();

        if (SettingsManager.GetBoolean("HIDvibrateonconnect"))
            targetController.Rumble(targetController.GetUserIndex() + 1);

        if (SettingsManager.GetBoolean("HIDcloakonconnect"))
            targetController.Hide();

        // update settings
        SettingsManager.SetProperty("HIDInstancePath", baseContainerDeviceInstanceId);

        // warn service a new controller has arrived
        PipeClient.SendMessage(
            new PipeClientControllerConnect(targetController.ToString(), targetController.Capacities));

        // check applicable scenarios
        CheckControllerScenario();

        // raise event
        ControllerSelected?.Invoke(targetController);
    }

    private static void OnClientConnected()
    {
        // warn service a new controller has arrived
        if (targetController is null)
            return;

        PipeClient.SendMessage(
            new PipeClientControllerConnect(targetController.ToString(), targetController.Capacities));
    }

    public static IController GetTargetController()
    {
        return targetController;
    }

    public static bool HasPhysicalController()
    {
        return GetPhysicalControllers().Count() != 0;
    }

    public static bool HasVirtualController()
    {
        return GetVirtualControllers().Count() != 0;
    }

    public static IEnumerable<IController> GetPhysicalControllers()
    {
        return Controllers.Values.Where(a => !a.IsVirtual()).ToList();
    }

    public static IEnumerable<IController> GetVirtualControllers()
    {
        return Controllers.Values.Where(a => a.IsVirtual()).ToList();
    }

    public static List<IController> GetControllers()
    {
        return Controllers.Values.ToList();
    }

    private static void UpdateInputs(ControllerState controllerState)
    {
        ButtonState buttonState = controllerState.ButtonState.Clone() as ButtonState;

        // raise event
        InputsUpdated?.Invoke(controllerState);

        // pass inputs to Inputs manager
        InputsManager.UpdateReport(buttonState);

        // pass inputs to Overlay Model
        MainWindow.overlayModel.UpdateReport(controllerState);

        // pass inputs to Layout manager
        controllerState = LayoutManager.MapController(controllerState);

        // controller is muted
        if (ControllerMuted)
            return;

        // check if motion trigger is pressed
        var currentProfile = ProfileManager.GetCurrent();
        controllerState.MotionTriggered = (currentProfile.MotionMode == MotionMode.Off &&
                                           buttonState.ContainsTrue(currentProfile.MotionTrigger)) ||
                                          (currentProfile.MotionMode == MotionMode.On &&
                                           !buttonState.ContainsTrue(currentProfile.MotionTrigger));

        // pass inputs to service
        PipeClient.SendMessage(new PipeClientInputs(controllerState));
    }

    private static void UpdateMovements(ControllerMovements Movements)
    {
        // pass movements to service
        PipeClient.SendMessage(new PipeClientMovements(Movements));
    }

    internal static IController GetEmulatedController()
    {
        var HIDmode = (HIDmode)SettingsManager.GetInt("HIDmode", true);
        switch (HIDmode)
        {
            default:
            case HIDmode.NoController:
            case HIDmode.Xbox360Controller:
                return emptyXInput;

            case HIDmode.DualShock4Controller:
                return emptyDS4;
        }
    }

    #region events

    public static event ControllerPluggedEventHandler ControllerPlugged;

    public delegate void ControllerPluggedEventHandler(IController Controller);

    public static event ControllerUnpluggedEventHandler ControllerUnplugged;

    public delegate void ControllerUnpluggedEventHandler(IController Controller);

    public static event ControllerSelectedEventHandler ControllerSelected;

    public delegate void ControllerSelectedEventHandler(IController Controller);

    public static event InputsUpdatedEventHandler InputsUpdated;

    public delegate void InputsUpdatedEventHandler(ControllerState Inputs);

    public static event InitializedEventHandler Initialized;

    public delegate void InitializedEventHandler();

    #endregion
}