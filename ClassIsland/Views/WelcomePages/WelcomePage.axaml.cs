using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.VisualTree;
using ClassIsland.Controls;
using ClassIsland.Core;
using ClassIsland.Core.Helpers.UI;
using ClassIsland.Core.Models.UI;
using ClassIsland.ViewModels;
using FluentAvalonia.UI.Controls;

namespace ClassIsland.Views.WelcomePages;

public partial class WelcomePage : UserControl, IWelcomePage
{
    private WelcomeViewModel _viewModel = null!;

    public WelcomeViewModel ViewModel
    {
        get => _viewModel;
        set
        {
            _viewModel = value;
            DataContext = this;
        }
    }

    public WelcomePage()
    {
        InitializeComponent();
    }

    private void ButtonNext_OnClick(object? sender, RoutedEventArgs e)
    {
        NavigateNext();
    }

    private void NavigateNext()
    {
        this.ShowToast(new ToastMessage()
        {
            Title = "Welcome to CIIEC",
            Message = "CIIEC is a free open-source software, offically, there are absolutely no payment-required services provided, the source URL is https://github.com/HuaLaNN-HS/ClassIsland-Intl-Edition-Community, and the original repository's source code is at https://github.com/ClassIsland/ClassIsland. If you've aquired this software through paid assistance, it's recommended to seek help under the architecture of your provider when you encounter problems. If the provider didn't provide estimated service, please seek for a refund or actively protect your legal rights through other ways.",
            AutoClose = false,
            Severity = FAInfoBarSeverity.Warning
        });
        WelcomeWindow.WelcomeNavigateForwardCommand.Execute(this);
    }

    private void Intro_OnAnimationEnd(object? sender, EventArgs e)
    {
        ContentRoot.Classes.Add("anim");
    }

    private void ButtonDataMigration_OnClick(object? sender, RoutedEventArgs e)
    {
        var welcomeWindow = this.FindAncestorOfType<WelcomeWindow>();
        if (welcomeWindow == null)
        {
            return;
        }

        welcomeWindow.Pages.Clear();
        welcomeWindow.Pages.AddRange([typeof(WelcomePage), typeof(LicensePage), typeof(DataTransferPage)]);
        
        NavigateNext();
    }

    private void ButtonEnterRecovery_OnClick(object? sender, RoutedEventArgs e)
    {
        AppBase.Current.Restart(["-m", "-r"]);
    }

    private void ButtonJoinManagement_OnClick(object? sender, RoutedEventArgs e)
    {
        var dialog = new JoinManagementDialog();
        dialog.ShowDialog((TopLevel.GetTopLevel(this) as Window)!);
    }
}