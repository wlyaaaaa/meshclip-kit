@{
    Severity = @('Error', 'Warning')

    # These entry scripts are interactive operators, so host output is intentional.
    # State-changing helpers are private implementation details called only behind
    # ShouldProcess-enabled entry points. Their names favor clarity over gallery
    # cmdlet naming conventions.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
