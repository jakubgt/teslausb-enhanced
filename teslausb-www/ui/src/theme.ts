import { createContext } from 'react';

// True when dark mode is active. Lets plain elements (logs, header) adapt.
export const ThemeContext = createContext<boolean>(false);
