{delib, ...}:
delib.module {
  name = "constants";

  options.constants = with delib; {
    username = readOnly (strOption "marshall");
    userfullname = readOnly (strOption "Mars");
    useremail = readOnly (strOption "mars@pupbrained.dev");
  };
}
