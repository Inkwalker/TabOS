return {
    description = "Edit a text file. Usage: edit <path>.",
    operands = "<path>",
    count = 1,
    handler = function(_, path)
        shell.run_app("/rec/editor.tap", {path})
    end,
}
