require "json"
require "find"

VariableName = ARGV[0]
InputPath    = ARGV[1]
OutputPath   = ARGV[2]


def parseComponent(value)
    if value.kind_of? String then
        if value.include?(".") then
            return value.to_f
        elsif value.include?("0x") then
            return value.to_i(16).to_f / 255.0
        else 
            return value.to_i.to_f / 255.0
        end
    end

    return nil
end


def parseColor(color)
    colorSpace = color && color["color-space"]
    components = color && color["components"]

    if colorSpace == "srgb" and components then
        r = parseComponent(components["red"])
        g = parseComponent(components["green"])
        b = parseComponent(components["blue"])
        a = parseComponent(components["alpha"])

        return "#{r}, #{g}, #{b}, #{a}"
    end

    return nil
end

OutputLines = [ ]

Find.find(InputPath) do |path|
    if m = path.match(/\/(\w*?)\.colorset\/Contents.json$/) then
        root = JSON.parse(File.read(path))
        result = nil
        name = m[1]

        root["colors"].each do |color|
            next if color["appearances"]

            gamut = color["display-gamut"]
            next if gamut == "display-P3"
            
            result = parseColor(color["color"])
        end

        if result then
            OutputLines.push("    { \"#{name}\", #{result} },")
        else
            STDERR.puts "Could not find legacy color for \"#{name}\" color set"
            exit(2)
        end
    end
end

OutputLines.unshift(
    "const struct { char *n; float r; float g; float b; float a; } " +
    VariableName + "[] = {"
)

OutputLines.push("    { NULL, 0, 0, 0, 0 }")
OutputLines.push("};")
OutputLines.push("")

open(OutputPath, "w") do |f|
    f << OutputLines.join("\n")
end
