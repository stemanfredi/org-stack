import jakarta.servlet.*;
import jakarta.servlet.http.*;
import java.io.IOException;
import java.security.Principal;
import java.util.*;

/**
 * Servlet Filter that wraps requests to provide Remote-User authentication from Authelia
 */
public class RemoteUserFilter implements Filter {

    @Override
    public void init(FilterConfig filterConfig) throws ServletException {
        // Nothing to initialize
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest httpRequest = (HttpServletRequest) request;
        String remoteUser = httpRequest.getHeader("Remote-User");

        if (remoteUser != null && !remoteUser.isEmpty()) {
            // Wrap the request to override getRemoteUser() and getUserPrincipal()
            HttpServletRequestWrapper wrapper = new HttpServletRequestWrapper(httpRequest) {
                @Override
                public String getRemoteUser() {
                    return remoteUser;
                }

                @Override
                public Principal getUserPrincipal() {
                    return new Principal() {
                        @Override
                        public String getName() {
                            return remoteUser;
                        }
                    };
                }

                @Override
                public boolean isUserInRole(String role) {
                    String remoteGroups = httpRequest.getHeader("Remote-Groups");
                    if (remoteGroups != null) {
                        return Arrays.asList(remoteGroups.split(","))
                                    .contains(role);
                    }
                    // All authenticated users have "Authenticated" role
                    return "Authenticated".equals(role);
                }
            };
            chain.doFilter(wrapper, response);
        } else {
            chain.doFilter(request, response);
        }
    }

    @Override
    public void destroy() {
        // Nothing to clean up
    }
}
