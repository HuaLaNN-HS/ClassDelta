
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Resources;

namespace ClassIsland.Services;

public sealed record UiLanguageOption(
    string Code,
    string DisplayName);

public sealed class UiLocalizationService : INotifyPropertyChanged
{
    public static UiLocalizationService Instance { get; } = new();

    public static IReadOnlyList<UiLanguageOption> SupportedLanguages { get; } =
    [
        new("en-US", "English"),
    ];

    private readonly ResourceManager _resources = new(
        "ClassIsland.Assets.Localization.Localization.Main.Strings",
        typeof(UiLocalizationService).Assembly);

    private CultureInfo _culture =
        CultureInfo.GetCultureInfo("en-US");

    public event PropertyChangedEventHandler? PropertyChanged;

    public string this[string key] =>
        _resources.GetString(key, _culture) ?? $"[{key}]";

    public void SetLanguage(string? language)
    {
        _culture = language switch
        {
            "en-US" => CultureInfo.GetCultureInfo("en-US"),
            _ => CultureInfo.GetCultureInfo("en-US")
        };

        PropertyChanged?.Invoke(
            this,
            new PropertyChangedEventArgs("Item[]"));
    }
}
