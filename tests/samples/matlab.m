% Plot a sine wave.
%{
Block comment.
%}
function y = wave(n)
    x = linspace(0, 2*pi, n);
    y = sin(x);
    plot(x, y);
    title('Sine');
    disp("done")
end
